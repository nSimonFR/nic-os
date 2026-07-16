# nextcloud.nix — Nextcloud serving Files (replaces filebrowser) + Contacts +
# Calendar + Tasks via DAV. Nextcloud's home is /mnt/data/nextcloud (the HDD);
# the nixpkgs module places config at <home>/config/ and data at <home>/data/,
# so user files live at /mnt/data/nextcloud/data/nsimon/files/{ADMINISTRATIVE,
# ...}. /mnt/data/cloud is a bind-mount of that user-files dir, exposing a
# clean view (no Nextcloud config/, data/, appdata_* internals) to the
# Tailscale Drive share defined in tailscale-serve.nix.
# Calendars/addressbooks stay in PostgreSQL.
#
# Same shape as sure.nix / airtrail.nix: shared system PostgreSQL + shared
# Redis, password set via a oneshot ALTER USER service, secrets via agenix.
{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, ... }:
let
  # Internal nginx port. Nextcloud is served at https://<tailnetFqdn>/nextcloud on the
  # public 443 Tailscale Funnel via the nginx path-mux (front-proxy.nix), which strips
  # the /nextcloud prefix and forwards to this port on 127.0.0.1. `overwritewebroot`
  # below makes Nextcloud generate its links under /nextcloud to match.
  port = 8091;

  # Datadir on the data HDD. Nextcloud manages this tree exclusively:
  # per-user files at /mnt/data/nextcloud/data/<user>/files/, plus internal
  # markers (.htaccess, .ocdata, appdata_*). /mnt/data/cloud is bind-mounted
  # to this user's files dir below — see the systemd.mounts block.
  datadir = "/mnt/data/nextcloud";

  # Shared Redis DB index. 0=AFFiNE, 1=Immich, 2=Sure, 3=Dawarich, 4=free (was Paperless).
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
    # ── Custom CSS (edit via Theming admin → Custom CSS) ──────────────────
    "theming_customcss"
    # ── Productivity / collaboration ──────────────────────────────────────
    "cospend"           # Group expenses split (trips, colocs)
    "cookbook"          # Recipe manager with schema.org URL import
    # ── Mail (IMAP/SMTP through hydroxide bridge) ─────────────────────────
    "mail"
    # ── Forced by Nextcloud core (occ app:disable refuses) ────────────────
    "cloud_federation_api"
    "federatedfilesharing"
    "lookup_server_connector"
    "viewer"
    "workflowengine"
  ];

  # Shared shape for the Nextcloud orchestration oneshots below.
  mkServiceConfig = { description, syslog, after, requires, script, before ? [ ] }: {
    inherit description after before requires script;
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = syslog;
    };
  };
in
{
  # ── PostgreSQL: nextcloud_production database + nextcloud_user ─────────────
  services.postgresql = {
    ensureDatabases = [ "nextcloud_production" ];
    ensureUsers = [{
      name = "nextcloud_user";
      # ensureDBOwnership requires db name == username; granted in
      # nextcloud-pg-setup below (same caveat as sure/airtrail).
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

    # DISABLED: appstoreEnable = true causes app-store mail to conflict with
    # extraApps mail, triggering "Cannot redeclare class ComposerAutoloaderInitMail".
    # See [[known_issue_nextcloud_extraapps_appstore_dup]]. Post-setup enablement
    # is instead handled by nextcloud-appstore-enable below.
    appstoreEnable = false;

    # Storage path on the data HDD. The nixpkgs module treats datadir as
    # Nextcloud's *home*: it creates /mnt/data/nextcloud/config/ (config.php)
    # and /mnt/data/nextcloud/data/ (.htaccess, .ncdata, appdata_*, per-user
    # files at data/<user>/files/).
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
    # NOTE: mail is excluded to avoid app-store duplicate conflicts (see
    # [[known_issue_nextcloud_extraapps_appstore_dup]]) — it's installed by
    # nextcloud-appstore-enable instead.
    extraApps = {
      inherit (pkgs.nextcloud33Packages.apps) contacts calendar tasks;
    };
    extraAppsEnable = true;

    # Default settings; the module merges these into config.php.
    settings = {
      trusted_domains   = [ tailnetFqdn ];
      trusted_proxies   = [ "127.0.0.1" ];
      overwriteprotocol = "https";
      overwritehost     = tailnetFqdn; # bare host on the 443 Funnel (no port suffix)
      # Served behind the nginx path-mux at /nextcloud (front-proxy.nix strips the
      # prefix); overwritewebroot makes Nextcloud regenerate its links under /nextcloud.
      overwritewebroot  = "/nextcloud";
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

      # ── System SMTP via hydroxide ProtonMail bridge ──────────────────────
      # Used for calendar invites, share notifications, password resets.
      # mail_smtppassword is set at runtime by nextcloud-mail-account-setup
      # (it's a secret, can't go in nix store). All other keys go here so
      # they aren't overridden by the nextcloud module's defaults JSON.
      mail_smtphost     = "127.0.0.1";
      mail_smtpport     = 1025;
      mail_smtpsecure   = "";          # plaintext on localhost, no TLS
      mail_smtpauth     = true;
      mail_smtpname     = "nsimon@protonmail.com";
      mail_smtpmode     = "smtp";
      mail_from_address = "nsimon";
      mail_domain       = "protonmail.com";
    };

    # PHP-FPM tuning for a 4-GiB RPi5 sharing with Immich/HA/AFFiNE/Sure.
    # pm = ondemand: workers fork on demand and exit after process_idle_timeout
    # of inactivity. Saves ~120 MiB when nobody is hitting the Nextcloud UI;
    # DAV reachability is unaffected because nginx still listens and php-fpm
    # spins a worker on the next request (~50ms cost vs `dynamic`).
    poolSettings = {
      "pm"                       = "ondemand";
      "pm.max_children"          = "8";
      "pm.process_idle_timeout"  = "60s";
      "pm.max_requests"          = "500";
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

  # ── Nextcloud service orchestration ──────────────────────────────────────────
  # Prevents "Cannot redeclare class" crash when extraApps + appstore both provide
  # the same app (see [[known_issue_nextcloud_extraapps_appstore_dup]]).
  # Order: cleanup → setup → appstore-enable → disable-defaults.

    systemd.services.nextcloud-cleanup = mkServiceConfig {
      description = "Nextcloud: cleanup store-apps duplicates and stale maintenance mode";
      syslog = "nextcloud-cleanup";
      after = [ "nextcloud-pg-setup.service" ];
      before = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-pg-setup.service" ];
      script = ''
        set -eu
        store_apps="${datadir}/store-apps"
        config_php="${datadir}/config/config.php"
        for app in mail contacts calendar tasks; do
          app_dir="$store_apps/$app"
          [ -d "$app_dir" ] && [ ! -L "$app_dir" ] && rm -rf "$app_dir"
        done
        grep -q "'maintenance' => true" "$config_php" 2>/dev/null && \
          ${pkgs.gnused}/bin/sed -i "s/'maintenance' => true,/'maintenance' => false,/" "$config_php" || true
      '';
    };

    systemd.services.nextcloud-setup = {
      after    = [ "nextcloud-cleanup.service" ];
      requires = [ "nextcloud-cleanup.service" ];
    };

    systemd.services.nextcloud-appstore-enable = mkServiceConfig {
      description = "Nextcloud: exit maintenance and install non-bundled apps";
      syslog = "nextcloud-appstore";
      after = [ "nextcloud-setup.service" "phpfpm-nextcloud.service" ];
      before = [ "nextcloud-disable-defaults.service" ];
      requires = [ "nextcloud-setup.service" ];
      script = ''
        ${config.services.nextcloud.occ}/bin/nextcloud-occ maintenance:mode --off
        for app in assistant integration_openai; do
          ${config.services.nextcloud.occ}/bin/nextcloud-occ app:install "$app" 2>/dev/null || true
        done
      '';
    };

    systemd.services.nextcloud-disable-defaults = mkServiceConfig {
      description = "Nextcloud: enforce app whitelist";
      syslog = "nextcloud-whitelist";
      after = [ "nextcloud-appstore-enable.service" "phpfpm-nextcloud.service" ];
      requires = [ "nextcloud-appstore-enable.service" ];
      script = ''
        set -eu
        occ="${config.services.nextcloud.occ}/bin/nextcloud-occ"
        keep=" ${lib.concatStringsSep " " appsToKeep} "
        # occ prints warnings (e.g. an orphaned apps_paths entry after a
        # package bump) to *stdout* ahead of the JSON, which would break the
        # jq parse and fail the unit. Strip everything before the first `{`.
        enabled_str=$($occ app:list --output=json 2>/dev/null | sed -n '/^{/,$p' | ${pkgs.jq}/bin/jq -r '.enabled | keys[]')
        for app in $enabled_str; do
          case "$keep" in
            *" $app "*) ;;
            *) $occ app:disable "$app" 2>/dev/null || true ;;
          esac
        done
        for app in${lib.concatMapStrings (a: " ${a}") appsToKeep}; do
          echo "$enabled_str" | grep -q "^$app$" || $occ app:enable "$app" 2>/dev/null || true
        done
      '';
    };

  # ── Bind-mount /mnt/data/cloud → user-files dir ────────────────────────────
  # Tailscale Drive shares /mnt/data/cloud (see tailscale-serve.nix). Bind-
  # mounting the user-files dir there gives Drive clients a clean view of
  # just the user's files — no config/, data/, appdata_* leaking out.
  # Same shape as the SSD overlay in immich.nix: tmpfiles pre-creates the
  # mountpoint, systemd.mounts wires the bind into local-fs.target.
  systemd.tmpfiles.rules = [
    # The datadir parent must be root-owned. The Nextcloud module's tmpfiles
    # only manage <datadir>/config and <datadir>/data — when the parent is
    # owned by a non-privileged user, systemd-tmpfiles refuses to apply the
    # `L+ override.config.php` rule with "unsafe path transition", which
    # silently leaves the symlink stale and breaks `occ` boot ("data dir
    # invalid"). Owning the parent root:root removes the escalation.
    "d /mnt/data/nextcloud 0755 root root -"
    "d /mnt/data/cloud 0755 root root -"
  ];

  # Defensive: keep the user-files dir owned by the php-fpm user. If it ever ends
  # up root-owned (e.g. a stray privileged op in the tree), occ file scans fail
  # ("not writable") and files dropped via the drive/PAPRA feeder never become
  # visible to Nextcloud. A tmpfiles `z` rule can't repair this — systemd-tmpfiles
  # refuses the root→nextcloud "unsafe path transition" — so use a plain chown
  # oneshot (non-recursive: only the dir itself).
  systemd.services.nextcloud-files-owner = {
    description = "Ensure nsimon's Nextcloud files dir is owned by nextcloud";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/chown nextcloud:nextcloud ${datadir}/data/nsimon/files";
    };
  };
  systemd.mounts = [{
    where = "/mnt/data/cloud";
    what  = "${datadir}/data/nsimon/files";
    type  = "none";
    options = "bind";
    wantedBy = [ "local-fs.target" ];
  }];

  # ── serverinfo NC-Token for the homepage widget ──────────────────────────
  # The homepage Nextcloud widget hits the serverinfo API, which accepts an
  # `NC-Token` header. Basic auth as nsimon fails (401 — the homepage secret
  # isn't nsimon's login password, and we won't reset the user's password for a
  # stats tile). So set the serverinfo monitoring token to the existing
  # nextcloud-homepage-password value; the widget authenticates with the same
  # secret via `key` (HOMEPAGE_VAR_NEXTCLOUD_PASSWORD in homepage.nix). occ
  # invalidates the appconfig cache; idempotent (same value each boot).
  systemd.services.nextcloud-serverinfo-token = {
    description = "Set Nextcloud serverinfo NC-Token for the homepage widget";
    after    = [ "nextcloud-setup.service" "phpfpm-nextcloud.service" ];
    requires = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # The secret file has a stray trailing CR (\r); occ would store it as part
      # of the token, but the widget's NC-Token HTTP header drops the \r → the
      # stored token (73 bytes) wouldn't match the header (72) → 401. Strip
      # CR/LF so the stored token is the clean 72-char value.
      ${config.services.nextcloud.occ}/bin/nextcloud-occ config:app:set serverinfo token \
        --value="$(tr -d '\r\n' < /run/agenix/nextcloud-homepage-password)"
    '';
  };

  # ── Pre-seed Nextcloud Mail with a hydroxide-backed ProtonMail account ────
  # Runs once on first activation (sentinel-gated). Reads the bridge password
  # from agenix and registers it with the Mail app via occ. Idempotent.
  systemd.services.nextcloud-mail-account-setup = {
    description = "Pre-seed Nextcloud Mail account against hydroxide bridge";
    after    = [ "nextcloud-disable-defaults.service" "hydroxide.service" ];
    requires = [ "nextcloud-disable-defaults.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      OCC=${config.services.nextcloud.occ}/bin/nextcloud-occ
      password=$(cat /run/agenix/protonmail-bridge-password)

      # mail_smtppassword can't live in services.nextcloud.settings (world-
      # readable nix store). Set it every boot so it's always in sync with
      # the agenix-stored bridge password — the other mail_smtp* keys are
      # in settings and don't need re-application.
      $OCC config:system:set mail_smtppassword --value="$password"

      sentinel=${datadir}/.mail-account-seeded
      if [ -f "$sentinel" ]; then
        echo "[mail-setup] account already seeded, smtppassword refreshed"
        exit 0
      fi
      $OCC mail:account:create \
        nsimon "ProtonMail" "nsimon@protonmail.com" \
        127.0.0.1 1143 none "nsimon@protonmail.com" "$password" \
        127.0.0.1 1025 none "nsimon@protonmail.com" "$password"
      touch "$sentinel"
      echo "[mail-setup] Mail-app account seeded"
    '';
  };
}
