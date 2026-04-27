# nextcloud.nix — minimal Nextcloud focused on Contacts + Calendar + Tasks (DAV).
#
# Files/Photos/Talk/Mail/Activity etc. are disabled. Calendars and addressbooks
# are stored in PostgreSQL; the data dir on disk stays essentially empty.
#
# Same shape as paperless.nix: shared system PostgreSQL + shared Redis,
# password set via a oneshot ALTER USER service, secrets via agenix.
{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, ... }:
let
  # Internal nginx port; Tailscale Serve exposes this as HTTPS :3500 on the
  # tailnet (see services-registry.nix).
  port = 8091;

  # Shared Redis DB index. 0=AFFiNE, 1=Immich, 2=Sure, 3=Dawarich, 4=Paperless.
  redisDb = 5;

  # Defaults to disable post-install. core deps (`dav`, `files`, `settings`,
  # `theming`, `provisioning_api`, `comments`, `contactsinteraction`,
  # `notifications`, `oauth2`, `twofactor_backupcodes`, `serverinfo`) stay on —
  # `dav` is what powers Card/CalDAV.
  appsToDisable = [
    "activity"
    "circles"
    "cloud_federation_api"
    "dashboard"
    "federatedfilesharing"
    "federation"
    "files_external"
    "files_pdfviewer"
    "files_reminders"
    "files_sharing"
    "files_trashbin"
    "files_versions"
    "firstrunwizard"
    "logreader"
    "lookup_server_connector"
    "nextcloud_announcements"
    "password_policy"
    "photos"
    "privacy"
    "recommendations"
    "related_resources"
    "sharebymail"
    "support"
    "survey_client"
    "systemtags"
    "text"
    "updatenotification"
    "user_status"
    "viewer"
    "weather_status"
    "webhook_listeners"
    "workflowengine"
  ];
in
{
  # ── PostgreSQL: nextcloud_production database + nextcloud_user ─────────────
  services.postgresql = {
    ensureDatabases = [ "nextcloud_production" ];
    ensureUsers = [{
      name = "nextcloud_user";
      # ensureDBOwnership requires db name == username; granted in
      # nextcloud-pg-setup below (same caveat as sure/paperless).
    }];

    authentication = lib.mkAfter ''
      host  nextcloud_production  nextcloud_user  ${pgHost}/32  scram-sha-256
    '';
  };

  systemd.services.nextcloud-pg-setup = {
    description = "Set nextcloud_user PostgreSQL password + DB ownership";
    after    = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      PrivateUsers = lib.mkForce false; # RPi5 has no user namespaces
    };
    script = ''
      password=$(cat /run/agenix/nextcloud-pg-password)
      # psql -v interpolation requires stdin; -c silently drops :'pw'.
      ${pkgs.postgresql}/bin/psql -v pw="$password" <<< "ALTER USER nextcloud_user WITH PASSWORD :'pw';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE nextcloud_production OWNER TO nextcloud_user;"
    '';
  };

  # ── Nextcloud (native nixpkgs module) ──────────────────────────────────────
  services.nextcloud = {
    enable   = true;
    package  = pkgs.nextcloud31;
    hostName = tailnetFqdn;
    https    = true; # URLs generated as https:// (TLS terminated by Tailscale Serve)

    # First-boot install creates the admin and writes config.php.
    config = {
      adminuser     = "nsimon";
      adminpassFile = "/run/agenix/nextcloud-admin-password";

      dbtype     = "pgsql";
      # `dbhost` accepts a `host:port` suffix; the module has no `dbport` option.
      dbhost     = "${pgHost}:${toString pgPort}";
      dbname     = "nextcloud_production";
      dbuser     = "nextcloud_user";
      dbpassFile = "/run/agenix/nextcloud-pg-password";
    };

    # Don't let the module spawn its own redis-nextcloud daemon — we wire the
    # shared instance manually below. With `configureRedis = true` the module
    # would also force settings.redis.{host,port} to a Unix socket on its own
    # daemon, conflicting with our overrides.
    configureRedis = false;
    caching = {
      redis = true;
      apcu  = true; # local opcode/data cache
    };

    # Pre-install Contacts, Calendar, Tasks. extraAppsEnable enables them on
    # first boot. The tasks app provides a web UI for VTODOs that already flow
    # through CalDAV; disabling the UI later is one `occ app:disable`.
    extraApps = {
      inherit (pkgs.nextcloud31Packages.apps) contacts calendar tasks;
    };
    extraAppsEnable = true;

    # Default settings; the module merges these into config.php.
    settings = {
      trusted_domains   = [ tailnetFqdn "${tailnetFqdn}:3500" ];
      trusted_proxies   = [ "127.0.0.1" ];
      overwriteprotocol = "https";
      overwritehost     = "${tailnetFqdn}:3500";
      overwritecondaddr = "^127\\.0\\.0\\.1$";

      # Default phone region for unparsed numbers in addressbooks (Contacts app
      # warning otherwise).
      default_phone_region = "FR";

      # Wire shared redis (databases.nix) for distributed cache + locking.
      # `configureRedis = false` above suppresses the module's auto-spawned
      # redis-nextcloud instance, so we set these keys ourselves.
      "memcache.distributed" = "\\OC\\Memcache\\Redis";
      "memcache.locking"     = "\\OC\\Memcache\\Redis";
      "memcache.local"       = "\\OC\\Memcache\\APCu";
      redis = {
        host    = redisHost;
        port    = redisPort;
        dbindex = redisDb;
      };

      # Calendars don't need server-side encryption; explicitly off.
      "encryption.enabled" = false;
      maintenance_window_start = 1; # 01:00 UTC daily window for occ background jobs
    };

    # PHP-FPM tuning for a 4-GiB RPi5 sharing with Immich/HA/AFFiNE/Sure.
    poolSettings = {
      "pm"                   = "dynamic";
      "pm.max_children"      = "8";
      "pm.start_servers"     = "2";
      "pm.min_spare_servers" = "1";
      "pm.max_spare_servers" = "3";
      "pm.max_requests"      = "500";
    };

    phpOptions = {
      "opcache.memory_consumption"    = "96";
      "opcache.interned_strings_buffer" = "12";
      "opcache.max_accelerated_files" = "10000";
      "opcache.revalidate_freq"       = "60";
    };
  };

  # Bind nginx vhost to 127.0.0.1:<port> only. Tailscale Serve forwards from
  # the tailnet interface; no need to listen on the Internet.
  services.nginx.virtualHosts.${tailnetFqdn}.listen = lib.mkForce [
    { addr = "127.0.0.1"; port = port; ssl = false; }
  ];

  # nextcloud-setup runs occ maintenance:install — must wait for postgres role
  # to have its password set. The module already orders after postgresql.service.
  systemd.services.nextcloud-setup = {
    after    = [ "nextcloud-pg-setup.service" ];
    requires = [ "nextcloud-pg-setup.service" ];
  };

  # ── Disable default apps after install ──────────────────────────────────────
  # `occ app:disable` is idempotent on already-disabled apps but may exit
  # nonzero on unknown app IDs (e.g. removed in a future version) — wrap with
  # `|| true` to keep the unit green.
  systemd.services.nextcloud-disable-defaults = {
    description = "Disable Nextcloud default apps not needed for Contacts/Calendar/Tasks";
    after    = [ "nextcloud-setup.service" "phpfpm-nextcloud.service" ];
    requires = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.concatMapStringsSep "\n" (app: ''
        ${config.services.nextcloud.occ}/bin/nextcloud-occ app:disable ${app} || true
      '') appsToDisable}
    '';
  };
}
