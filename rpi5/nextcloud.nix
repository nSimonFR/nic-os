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

  # Whitelist of apps to keep enabled. Anything currently-enabled and not on
  # this list is disabled by nextcloud-disable-defaults below.
  #
  # Two groups: core (Nextcloud breaks if these are off) and PIM (the features
  # we actually want — Contacts/Calendar/Tasks via DAV).
  appsToKeep = [
    # ── Core: required for the server itself ──────────────────────────────
    "dav"                  # CalDAV/CardDAV — the whole point
    "files"                # core files app; disabling breaks the web UI
    "settings"             # admin/personal settings UI
    "theming"              # branding/colors
    "provisioning_api"     # users/groups REST API (DAVx⁵ / clients use it)
    "oauth2"               # OAuth provider — needed for app passwords
    "twofactor_backupcodes"
    "twofactor_totp"
    "notifications"        # client-sync notifications
    "comments"             # core dependency of files
    "contactsinteraction"  # "recently contacted" sidebar feed for Contacts
    "serverinfo"           # /ocs/v2.php/apps/serverinfo (homepage widget hook)
    "bruteforcesettings"   # rate-limit failed logins
    "app_api"              # ExApps framework (required by core in v33+)
    "profile"              # user profile pages
    # ── PIM: the apps this deployment exists to serve ─────────────────────
    "calendar"
    "contacts"
    "tasks"
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
    # postgresql-setup.service is the unit that runs ensureUsers/ensureDatabases;
    # ordering only after postgresql.service races it and finds no role.
    after    = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
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
    package  = pkgs.nextcloud33;
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
      inherit (pkgs.nextcloud33Packages.apps) contacts calendar tasks;
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

  # ── Whitelist enforcement: disable anything not on appsToKeep ──────────────
  # Reads the currently-enabled set from occ at runtime and disables anything
  # not on the keep-list. Robust against:
  #   • new default apps in future Nextcloud majors
  #   • apps the package metadata re-enables after upgrades (e.g. `viewer`,
  #     `workflowengine` came back even after the previous blacklist run)
  #   • app IDs we've never heard of
  # Idempotent — `app:disable` on an already-disabled app is a no-op.
  systemd.services.nextcloud-disable-defaults = {
    description = "Enforce Nextcloud app whitelist (disable anything not in appsToKeep)";
    after    = [ "nextcloud-setup.service" "phpfpm-nextcloud.service" ];
    requires = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      keep=" ${lib.concatStringsSep " " appsToKeep} "
      enabled=$(${config.services.nextcloud.occ}/bin/nextcloud-occ app:list --output=json \
        | ${pkgs.jq}/bin/jq -r '.enabled | keys[]')
      for app in $enabled; do
        case "$keep" in
          *" $app "*) ;;
          *) ${config.services.nextcloud.occ}/bin/nextcloud-occ app:disable "$app" || true ;;
        esac
      done
    '';
  };
}
