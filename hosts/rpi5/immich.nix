{ pkgs, lib, unstablePkgs, redisHost, redisPort, beastHost, immichVersion, ... }:
let
  # externalPort: where mobile/web clients reach Immich (Tailscale Funnel
  # terminates :10000 → http://127.0.0.1:2283). backendPort: where Immich
  # actually binds, behind the socket-activate proxy.
  externalPort = 2283;
  backendPort  = 2284;
in
{
  services.immich = {
    enable        = true;
    package       = unstablePkgs.immich;
    port          = backendPort;
    host          = "127.0.0.1";
    mediaLocation = "/mnt/data/immich";

    # No local ML: inference runs on beast's GPU (hosts/beast/immich-ml.nix). The
    # rpi5's CPU could only run the tiny default CLIP; beast runs the largest
    # model. Trade-off: when beast is offline, new photos aren't embedded until
    # it returns (recovered via a "Missing" Smart-Search reprocess). Search over
    # already-embedded photos is unaffected.
    machine-learning.enable = false;

    # Point the server at beast's ML over the tailnet (MagicDNS name, not a raw
    # 100.x IP — see beastHost in flake.nix) and pin the models declaratively.
    # settings != null makes these read-only in the admin UI. Changing
    # clip.modelName forces a one-time full-library re-embed on beast.
    settings.machineLearning = {
      enabled = true;
      urls    = [ "http://${beastHost}:3003" ];
      clip = {
        enabled   = true;
        modelName = "ViT-H-14-378-quickgelu__dfn5b"; # largest CLIP (quality ~0.83)
      };
      facialRecognition = {
        enabled   = true;
        modelName = "buffalo_l";
      };
    };

    # External workflow plugins (IMMICH_ALLOW_EXTERNAL_PLUGINS + the install
    # folder) are switched on from immich-clip.nix, which owns the one plugin we
    # ship. `environment` merges across modules, so nothing about it lives here.

    # Use the shared Redis (databases.nix) on DB 1 via TCP instead of a
    # dedicated redis-immich instance. Saves ~7 MB RAM + one systemd unit.
    redis = {
      enable = false;
      host   = redisHost;
      port   = redisPort;
    };
    environment.REDIS_DBINDEX = "1";
    # The module hardcodes this to localhost:3003 (no mkDefault); force it to
    # beast so the server never falls back to a now-nonexistent local ML.
    # Belt-and-suspenders alongside settings.machineLearning.urls above.
    environment.IMMICH_MACHINE_LEARNING_URL = lib.mkForce "http://${beastHost}:3003";
  };

  # Version lock-step guard: beast's ML worker (hosts/beast/immich-ml.nix) must run
  # the same Immich version as this server. Both derive from the shared
  # immichVersion (flake.nix); assert the local package agrees so a bad pin
  # fails the build instead of breaking ML at runtime.
  assertions = [
    {
      assertion = unstablePkgs.immich.version == immichVersion;
      message =
        "rpi5 immich (${unstablePkgs.immich.version}) != shared immichVersion "
        + "(${immichVersion}); keep flake.nix immichVersion in sync with nixpkgs-unstable.";
    }
  ];

  # Ensure Immich starts after HDD is mounted.
  systemd.services.immich-server = {
    after = [ "mnt-data.mount" ];
    wants = [ "mnt-data.mount" ];
    environment.MALLOC_ARENA_MAX = "2";
    serviceConfig = {
      ExecStartPre = [
        "+${pkgs.coreutils}/bin/chown immich:immich /mnt/data/immich"
      ];
      # NestJS module init has a brief spike past steady-state RSS; the
      # extra headroom prevents the cgroup OOMing the process mid-boot
      # (cold-start now happens per socket-activate wake, not just at boot).
      MemoryMax = "768M";
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/data/immich 0750 immich immich -"
    # SSD-backed dirs for fast access (bind-mounted from /var/lib/immich)
    "d /var/lib/immich/thumbs 0750 immich immich -"
    "d /var/lib/immich/encoded-video 0750 immich immich -"
    "d /var/lib/immich/profile 0750 immich immich -"
    "d /var/lib/immich/backups 0750 immich immich -"
  ];

  # Bind SSD dirs into the HDD mediaLocation so immich finds them there.
  # library + upload stay on HDD; thumbs, encoded-video, profile, backups on SSD.
  systemd.mounts = map (sub: {
    where = "/mnt/data/immich/${sub}";
    what = "/var/lib/immich/${sub}";
    type = "none";
    options = "bind";
    wantedBy = [ "local-fs.target" ];
  }) [ "thumbs" "encoded-video" "profile" "backups" ];

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ──────────
  # Immich is the first Funnel-exposed service in the socket-activate set:
  # idleSec=1800 (not 600) dampens wake noise from public bot probes hitting
  # the :10000 funnel URL. There is no local ML worker to sleep with anymore
  # (ML runs on beast) — the API tier sleeps on its own. BullMQ jobs queue in
  # Redis and resume on wake; @nestjs/schedule cron ticks (NightlyJobs,
  # VersionCheck, LibraryScan) that fall in the asleep window are missed
  # and fire on the next wake instead — all idempotent.
  services.socketActivate.immich = {
    enable    = true;
    realUnit  = "immich-server.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 1800;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/api/server/ping";
      expectStatus = 200;
      timeoutSec   = 60;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  # library + upload live on the HDD under /mnt/data/immich, so restic covers
  # the photos directly.
  #
  # The database is a different story, and it took a 34-day outage to notice.
  # Immich's own nightly dump goes to /mnt/data/immich/backups, which is a bind
  # mount of the SSD — restic's --one-file-system (storj-backup.nix) does not
  # cross it, so those dumps never leave the machine. That job had ALSO been
  # failing every night since 2026-07-09 (pg_dump denied on postgres-owned tables
  # left behind by a face re-merge), and Immich's own job-queue counter reported
  # `backupDatabase: failed 0` throughout.
  #
  # So the photos were covered and the database that indexes them was not, by two
  # independent failures at once. `postgres` here puts it in
  # services.postgresqlBackup, whose dumps land on the HDD and DO reach Storj —
  # a path that does not depend on Immich's own job working, or on anyone
  # noticing that it has stopped.
  nic.services.immich = {
    backup            = [ "mnt-data" "postgres" ];
    postgresDatabases = [ "immich" ];
    heavyUnits    = [ "immich-server.service" ];
    heavyPriority = 10;

    public = {
      order   = 100;
      port    = 10000;
      backend = "http://127.0.0.1:2283";
      funnel  = true;
      tile = {
        name        = "Immich";
        icon        = "immich.svg";
        category    = "Apps";
        description = "Photo management";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/immich";
          refreshInterval = 3600000;
          mappings = [
            { field = "photos"; label = "Photos"; format = "number"; }
            { field = "videos"; label = "Videos"; format = "number"; }
            { field = "usage";  label = "Storage"; format = "bytes"; }
          ];
        };
      };
    };
  };
}
