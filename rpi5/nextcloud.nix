# nextcloud.nix — Nextcloud serving Files (replaces filebrowser) + Contacts +
# Calendar + Tasks via DAV. Nextcloud's home is /mnt/data/cloud (the HDD); the
# nixpkgs module places config at <home>/config/ and data at <home>/data/, so
# user files live at /mnt/data/cloud/data/nsimon/files/{ADMINISTRATIVE,...}.
# Calendars/addressbooks stay in PostgreSQL.
#
# Same shape as paperless.nix: shared system PostgreSQL + shared Redis,
# password set via a oneshot ALTER USER service, secrets via agenix.
{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, ... }:
let
  # Internal nginx port. Tailscale Serve exposes Nextcloud at :8085 on the
  # tailnet (the slot freed by filebrowser — see services-registry.nix) and
  # forwards to this port on 127.0.0.1.
  port = 8091;
  servePort = 8085; # external tailnet port (used in trusted_domains)

  # Datadir on the data HDD (was filebrowser's root). Nextcloud manages this
  # tree exclusively: per-user files at /mnt/data/cloud/<user>/files/, plus
  # internal markers (.htaccess, .ocdata, appdata_*).
  datadir = "/mnt/data/cloud";

  # Shared Redis DB index. 0=AFFiNE, 1=Immich, 2=Sure, 3=Dawarich, 4=Paperless.
  redisDb = 5;

  # Whitelist of apps to keep enabled. Anything currently-enabled and not on
  # this list is disabled by nextcloud-disable-defaults below.
  appsToKeep = [
    # ── Core: required for the server itself ──────────────────────────────
    "dav"                  # CalDAV/CardDAV
    "files"                # core files app
    "settings"             # admin/personal settings UI
    "theming"              # branding/colors
    "theming_customcss"    # admin custom CSS (nic-cloud 2026 glass theme; CSS lives in DB)
    "provisioning_api"     # users/groups REST API (DAVx⁵ / clients use it)
    "oauth2"               # OAuth provider — needed for app passwords
    "twofactor_backupcodes"
    "twofactor_totp"
    "notifications"        # client-sync notifications
    "comments"
    "contactsinteraction"  # "recently contacted" sidebar feed for Contacts
    "serverinfo"           # /ocs/v2.php/apps/serverinfo (homepage widget hook)
    "bruteforcesettings"   # rate-limit failed logins
    "app_api"              # ExApps framework (required by core in v33+)
    "profile"              # user profile pages
    # ── Files (filebrowser replacement) ────────────────────────────────────
    "files_sharing"        # internal share links + public links
    "files_versions"       # automatic file version history
    "files_trashbin"       # safety net before permanent delete
    "files_pdfviewer"      # in-browser PDF preview
    "files_downloadlimit"  # let admin cap download counts on shares
    "text"                 # collaborative text editor (md, txt)
    "systemtags"           # tag files for organisation
    "activity"             # change feed (file events) — useful as a log
    # ── PIM ───────────────────────────────────────────────────────────────
    "calendar"
    "contacts"
    "tasks"
    # ── AI assistant (chat, suggestions) routed through tiny-llm-gate :4001 ─
    "assistant"
    "integration_openai"
    # ── Forced by Nextcloud core (occ app:disable refuses) ────────────────
    "cloud_federation_api"
    "federatedfilesharing"
    "lookup_server_connector"
    "viewer"
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

    # Allow `occ app:install` to fetch from the Nextcloud app store. Used to
    # install assistant + integration_openai (not bundled with the package).
    appstoreEnable = true;

    # Storage path on the data HDD (was filebrowser's root). The nixpkgs
    # module treats datadir as Nextcloud's *home*: it creates
    # /mnt/data/cloud/config/ (config.php) and /mnt/data/cloud/data/
    # (.htaccess, .ncdata, appdata_*, per-user files at data/<user>/files/).
    inherit datadir;

    # First-boot install creates the admin and writes config.php. After that,
    # the admin password lives hashed in postgres oc_users and is rotated via
    # `occ user:resetpassword nsimon`. The placeholder file below is only read
    # if maintenance:install is run (i.e. on a fresh datadir); it never needs
    # to be a real secret and can sit world-readable in the nix store.
    config = {
      adminuser     = "nsimon";
      adminpassFile = builtins.toString (pkgs.writeText "nextcloud-admin-bootstrap-placeholder"
        "ChangeMeOnFreshInstallViaOccUserResetpassword");

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
      trusted_domains   = [ tailnetFqdn "${tailnetFqdn}:${toString servePort}" ];
      trusted_proxies   = [ "127.0.0.1" ];
      overwriteprotocol = "https";
      overwritehost     = "${tailnetFqdn}:${toString servePort}";
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

  # ── Whitelist enforcement: enable everything on appsToKeep, disable anything
  # else. Self-healing on every boot/rebuild. Robust against:
  #   • new default apps in future Nextcloud majors
  #   • apps the package re-enables on upgrade (viewer, workflowengine, etc.)
  #   • apps shipped-but-not-auto-enabled (files_pdfviewer was in the keep-list
  #     but stayed off because Nextcloud didn't auto-enable it on install)
  # Idempotent — `app:enable`/`app:disable` are no-ops on the current state.
  systemd.services.nextcloud-disable-defaults = {
    description = "Enforce Nextcloud app whitelist (enable keep-list, disable rest)";
    after    = [ "nextcloud-setup.service" "phpfpm-nextcloud.service" ];
    requires = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      OCC=${config.services.nextcloud.occ}/bin/nextcloud-occ
      JQ=${pkgs.jq}/bin/jq
      keep=" ${lib.concatStringsSep " " appsToKeep} "

      enabled=$($OCC app:list --output=json | $JQ -r '.enabled | keys[]')
      enabled_padded=" $(echo $enabled | tr '\n' ' ') "

      # Pass 1: enable any keep-list app that isn't already enabled.
      for app in${lib.concatMapStrings (a: " ${a}") appsToKeep}; do
        case "$enabled_padded" in
          *" $app "*) ;;
          *) $OCC app:enable "$app" || true ;;
        esac
      done

      # Pass 2: disable anything currently enabled and not on the keep-list.
      # Re-fetch in case pass 1 changed state (it should not bring in extras
      # but be defensive).
      enabled=$($OCC app:list --output=json | $JQ -r '.enabled | keys[]')
      for app in $enabled; do
        case "$keep" in
          *" $app "*) ;;
          *) $OCC app:disable "$app" || true ;;
        esac
      done
    '';
  };
}
