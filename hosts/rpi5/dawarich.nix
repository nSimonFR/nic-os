# dawarich.nix — self-hosted location history (Google Timeline alternative)
# Uses the native NixOS module (services.dawarich) — Rails + Sidekiq + PostGIS + Redis
{ config, pkgs, lib, unstablePkgs, tailnetFqdn, redisHost, redisPort, ... }:
let
  internalPort = 13900; # the wake socket; every caller uses this
  backendPort  = 13901; # Puma, behind the proxy
in
{
  services.dawarich = {
    enable = true;
    # release-25.11's dawarich is frozen at 1.7.5; track the unstable package
    # for the latest release (mirrors immich in hosts/rpi5/immich.nix).
    package = unstablePkgs.dawarich;
    localDomain = tailnetFqdn;
    webPort = backendPort;
    configureNginx = false; # Tailscale Serve handles HTTPS

    # Reuses existing PostgreSQL cluster; auto-adds "dawarich" DB + PostGIS extension
    database.createLocally = true;

    # Use the shared Redis (databases.nix) on DB 3 via TCP instead of a
    # dedicated redis-dawarich instance. Saves ~7 MB RAM + one systemd unit.
    redis = {
      createLocally = false;
      host          = redisHost;
      port          = redisPort;
    };

    # Auto-generate SECRET_KEY_BASE (stored at /var/lib/dawarich/secrets/secret-key-base)
    secretKeyBaseFile = null;

    # Reduce Sidekiq threads for RPi5 memory constraints
    sidekiqThreads = 1;

    environment = {
      TIME_ZONE = "Europe/Paris";
      # + the Agent Vault alias (hosts/rpi5/agent-vault.nix): Rails 403s other Hosts.
      APPLICATION_HOSTS = lib.mkForce "127.0.0.1,::1,${tailnetFqdn},dawarich.home.arpa";
      # Single-process Puma (no forked workers) — saves ~50 MB on RPi5
      WEB_CONCURRENCY = "0";
      # Match reduced thread count for web process
      RAILS_MAX_THREADS = "2";
      # Limit jemalloc memory arenas
      MALLOC_ARENA_MAX = "2";
      # Override upstream's REDIS_URL (which has no DB index) to isolate
      # Dawarich's keyspace on DB 3 of the shared Redis.
      REDIS_URL = "redis://${redisHost}:${toString redisPort}/3";
    };
  };

  # RPi5: PrivateUsers requires user namespaces, not supported on this kernel
  systemd.services.dawarich-web.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-sidekiq-all.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-init-db.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-init-credentials.serviceConfig.PrivateUsers = lib.mkForce false;

  # Memory limits — tightened for single-process mode
  systemd.services.dawarich-web.serviceConfig.MemoryMax = "256M";
  systemd.services.dawarich-sidekiq-all.serviceConfig.MemoryMax = "256M";

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ──────────
  # Cold start measured 2026-10-27: ~30 s on a quiet Pi, 4 min while swapping.
  # The iOS app keeps unsent points and re-sends them (an hour of outage arrived
  # in one batch), so a slow wake delays points rather than losing them.
  services.socketActivate.dawarich = {
    enable    = true;
    realUnit  = "dawarich-web.service";
    listen    = [ "127.0.0.1:${toString internalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 600;
    readyProbe = {
      url        = "http://127.0.0.1:${toString backendPort}/api/v1/health";
      timeoutSec = 300;
    };
    workers."dawarich-sidekiq-all.service".policy = "sleepWith";
  };
  # Upstream reruns migrations + seeds (20-35 s) on every web/sidekiq start, so on
  # every wake. Once per boot is enough; a new package changes the unit and reruns it.
  systemd.services.dawarich-init-db.serviceConfig.RemainAfterExit = true;

  # Geoapify reverse geocoding — drives visit suggestions (nightly sidekiq job)
  # and on-demand address lookups in the web UI.
  # Key is injected via EnvironmentFile to keep it out of the nix store.
  systemd.services.dawarich-web.serviceConfig.EnvironmentFile =
    "/run/agenix/dawarich-geoapify";
  systemd.services.dawarich-sidekiq-all.serviceConfig.EnvironmentFile =
    "/run/agenix/dawarich-geoapify";

  # Apple Health ride routes (FreeReps, ~1 Hz) and geotagged Immich photos →
  # Dawarich points. Root for `runuser -u postgres`: both DBs are read over the
  # socket, the API keys included.
  systemd.services.freereps-to-dawarich = {
    description = "Push FreeReps workout routes and Immich photo fixes into Dawarich";
    after    = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Wake Dawarich through its socket first: a cold start outlasts post_json's 60 s.
      ExecStartPre = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 300 http://127.0.0.1:${toString internalPort}/api/v1/health";
      ExecStart = [
        "${pkgs.nicos-scripts}/bin/freereps-to-dawarich"
        "${pkgs.nicos-scripts}/bin/immich-to-dawarich"
      ];
      StateDirectory = "freereps-to-dawarich";
      Environment = [
        "FREEREPS_DAWARICH_STATE=/var/lib/freereps-to-dawarich/pushed.json"
        "FREEREPS_DAWARICH_DRY_RUN=0"
        "IMMICH_DAWARICH_STATE=/var/lib/freereps-to-dawarich/immich.json"
        "IMMICH_DAWARICH_DRY_RUN=0"
        "DAWARICH_BASE_URL=http://127.0.0.1:${toString internalPort}"
        "PSQL_BIN=${config.services.postgresql.package}/bin/psql"
        "RUNUSER_BIN=${pkgs.util-linux}/bin/runuser"
      ];
    };
  };
  systemd.timers.freereps-to-dawarich = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:30:00"; Persistent = true; };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.dawarich = {
    backup            = [ "postgres" ];
    postgresDatabases = [ "dawarich" ];
    heavyUnits        = [ "dawarich-sidekiq-all.service" "dawarich-web.service" ];
    heavyPriority     = 40;

    public = {
      order   = 30;
      port    = 3900;
      backend = "http://127.0.0.1:${toString internalPort}";
      tile = {
        name        = "Dawarich";
        icon        = "dawarich.svg";
        category    = "Apps";
        description = "Location history";
        # Postgres read as superuser via the aggregator — no native widget, and no
        # role password on the tile.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/dawarich";
          refreshInterval = 3600000;
          mappings = [
            # `Points` was all-time (7,244) — a large, always-growing number that
            # hid the only thing worth knowing here: whether the phone is still
            # feeding it. It is barely feeding it, 134 points over 7 days, and that
            # starvation is exactly why DBSCAN has produced no new visit since
            # 2026-04-19 (known_issue_dawarich_no_visits_sparse_points). `Visits`
            # stays all-time on purpose — a "visits this week" field would read 0
            # and look like a display bug rather than the symptom it is.
            { field = "points_7d"; label = "Points 7d"; format = "number"; }
            { field = "trips";     label = "Trips";     format = "number"; }
            { field = "visits";    label = "Visits";    format = "number"; }
          ];
        };
      };
    };
  };
}
