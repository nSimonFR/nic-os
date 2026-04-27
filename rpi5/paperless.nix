{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, ... }:
let
  # Internal port; Tailscale Serve exposes this as HTTPS :3400 on the tailnet.
  # See rpi5/services-registry.nix.
  port = 8200;

  # Reuse the shared Redis on DB 4 (0=AFFiNE, 1=Immich, 2=Sure, 3=Dawarich).
  redisUrl = "redis://${redisHost}:${toString redisPort}/4";

  # Bills / invoices drop-zone. Top-level folder inside the user's Nextcloud
  # files tree. The nixpkgs nextcloud module nests data inside the home as
  # `<home>/data/<user>/files/...`, hence the `/data/` segment.
  consumeDir = "/mnt/data/cloud/data/nsimon/files/PAPERLESS";
in
{
  # ── PostgreSQL: paperless_production database + paperless_user ────────────
  # Same pattern as Sure: share the system PostgreSQL, set password via a
  # oneshot `ALTER USER` service reading an agenix secret (ensurePasswordFile
  # is not yet in NixOS 25.11).
  services.postgresql = {
    ensureDatabases = [ "paperless_production" ];
    ensureUsers = [{
      name = "paperless_user";
      # ensureDBOwnership requires db name == username; we grant ownership in
      # paperless-pg-setup below.
    }];

    # Allow paperless_user to connect via TCP with scram-sha-256 password auth.
    authentication = lib.mkAfter ''
      host  paperless_production  paperless_user  ${pgHost}/32  scram-sha-256
    '';
  };

  systemd.services.paperless-pg-setup = {
    description = "Set paperless_user PostgreSQL password + DB ownership";
    # Wait for postgresql-setup.service so ensureUsers has created paperless_user
    # before we ALTER it (otherwise: race; "role does not exist" on first boot).
    after    = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      # PrivateUsers = true (systemd default on some hardening stacks) requires
      # user namespaces, unsupported on RPi5. Keep explicit for clarity.
      PrivateUsers = lib.mkForce false;
    };
    script = ''
      password=$(cat /run/agenix/paperless-pg-password)
      # psql variable interpolation (:'pw') requires stdin/-f input; it is
      # silently skipped with -c, producing "syntax error at or near :".
      # Pipe via stdin. (Same caveat as sure-pg-setup.)
      ${pkgs.postgresql}/bin/psql -v pw="$password" <<< "ALTER USER paperless_user WITH PASSWORD :'pw';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE paperless_production OWNER TO paperless_user;"
    '';
  };

  # ── Paperless-ngx ──────────────────────────────────────────────────────────
  # Native nixpkgs 25.11 module. We point it at the shared PostgreSQL and
  # shared Redis (DB 4) instead of spinning up dedicated instances.
  services.paperless = {
    enable          = true;
    address         = "127.0.0.1";
    port            = port;
    consumptionDir  = consumeDir;
    # Admin password for the web UI superuser; created by the module's
    # scheduler preStart using manage_superuser the first time it runs.
    passwordFile    = "/run/agenix/paperless-admin-password";
    # Contains `PAPERLESS_DBPASS=...` (+ optionally PAPERLESS_SECRET_KEY).
    environmentFile = "/run/agenix/paperless-env";

    settings = {
      # Shared PostgreSQL (bypasses the module's localhost/peer-auth default).
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBHOST   = pgHost;
      PAPERLESS_DBPORT   = toString pgPort;
      PAPERLESS_DBNAME   = "paperless_production";
      PAPERLESS_DBUSER   = "paperless_user";

      # Reuse the shared Redis instance (DB 4) instead of spawning a dedicated
      # redis-paperless process (~12 MB saved). Setting PAPERLESS_REDIS disables
      # the module's automatic redis-paperless instance.
      PAPERLESS_REDIS = redisUrl;

      # Superuser auto-provisioned on first boot (see passwordFile above).
      PAPERLESS_ADMIN_USER = "nsimon";
      PAPERLESS_ADMIN_MAIL = "nsimon@nic-os.local";

      # OCR — French + English only. Additional languages would bloat the
      # tesseract closure considerably (module auto-selects lang packs from
      # PAPERLESS_OCR_LANGUAGE).
      PAPERLESS_OCR_LANGUAGE = "eng+fra";

      # Consumer: recurse into subdirectories and use their names as tags
      # (e.g. Payfit/, Ameli/). Ignore macOS resource forks.
      PAPERLESS_CONSUMER_RECURSIVE       = true;
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = true;
      PAPERLESS_CONSUMER_IGNORE_PATTERN = [
        ".DS_STORE/*"
        "._*"
        "desktop.ini"
      ];

      # ── RAM-conservative tuning for 4 GiB RPi5 ─────────────────────────────
      # Host already runs Immich, HA, AFFiNE, Sure, etc.  Targeting ≤500 MB
      # idle, ≤1 GiB during OCR bursts. earlyoom's --avoid list protects
      # postgres/redis; paperless workers are killable and resume via Celery.
      PAPERLESS_TASK_WORKERS       = 1;       # single celery worker process
      PAPERLESS_THREADS_PER_WORKER = 1;       # serial OCR, no per-task threading
      PAPERLESS_WEBSERVER_WORKERS  = 1;       # single granian worker (default 2)
      PAPERLESS_OCR_CLEAN          = "none";  # skip unpaper pre-clean pass
      PAPERLESS_ENABLE_NLTK        = false;   # skips NLTK data (~100 MB RAM)

      # Reverse-proxied via Tailscale Serve (see services-registry.nix).
      PAPERLESS_URL                  = "https://${tailnetFqdn}:3400";
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://${tailnetFqdn}:3400";
    };
  };

  # ── Celery solo pool: merge main + worker into one process (~70-100 MB saved)
  # With TASK_WORKERS=1 we already run serially; solo pool just avoids the
  # separate ForkPoolWorker process. Override the module's hardcoded ExecStart.
  systemd.services.paperless-task-queue.serviceConfig.ExecStart = lib.mkForce
    "${config.services.paperless.package}/bin/celery --app paperless worker --pool=solo --loglevel INFO";

  # ── Systemd hardening: disable PrivateUsers on RPi5 ────────────────────────
  # Memory entry "PrivateUsers RPi5": the raspberry-pi-5 firmware/kernel boots
  # with cgroup_disable=memory and without user-namespace support, so any unit
  # that inherits PrivateUsers=true from hardening presets fails to start.
  # The paperless module sets PrivateUsers = true in defaultServiceConfig.
  systemd.services.paperless-scheduler = {
    # Ensure migrations run only after the PG user is ready with a password.
    after    = [ "paperless-pg-setup.service" ];
    requires = [ "paperless-pg-setup.service" ];
    serviceConfig.PrivateUsers = lib.mkForce false;
  };
  systemd.services.paperless-task-queue.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.paperless-consumer.serviceConfig.PrivateUsers    = lib.mkForce false;
  systemd.services.paperless-web.serviceConfig.PrivateUsers         = lib.mkForce false;

  # Consume dir lives inside Nextcloud's per-user files tree as a top-level
  # folder. Parents (nsimon, nsimon/files) are nextcloud-owned so paperless
  # can traverse (mode 0755). The leaf itself is paperless-owned so the
  # consumer can write/delete. tmpfiles is a no-op if the path already exists.
  systemd.tmpfiles.settings."10-paperless-consume" = {
    "/mnt/data/cloud/data/nsimon".d = {
      user  = "nextcloud";
      group = "nextcloud";
      mode  = "0755";
    };
    "/mnt/data/cloud/data/nsimon/files".d = {
      user  = "nextcloud";
      group = "nextcloud";
      mode  = "0755";
    };
    "${consumeDir}".d = {
      user  = "paperless";
      group = "paperless";
      mode  = "0755";
    };
  };
}
