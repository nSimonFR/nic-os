{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, apertureUrl, ... }:
let
  # externalPort: where Tailscale Serve (→ :3333) and the socket-activate
  # proxy listen. backendPort: Sure's Puma binds here behind the proxy.
  externalPort = 13334;
  backendPort  = 13335;

  # Route Sure's assistant/merchant-detection LLM calls through tiny-llm-gate
  # on :4001 (which then fans out to codex-proxy or Ollama). These ENVs take
  # precedence over any DB `Setting.openai_*` — see Provider::Registry#openai.
  # Setting them here also avoids the hosting-settings UI accidentally
  # overwriting the route when the admin page is saved.
  sureLlmEnv = {
    OPENAI_URI_BASE     = "${apertureUrl}/v1/";
    # "auto" is a tiny-llm-gate virtual model that tries beast (Ollama
    # gemma4:e4b) first and falls back to codex gpt-5.5 if beast is
    # unreachable. See rpi5/tiny-llm-gate.nix `models."auto"`.
    OPENAI_MODEL        = "auto";
    OPENAI_ACCESS_TOKEN = "unused"; # real auth lives in codex-proxy OAuth
  };
in
{
  # ── for-sure: combined Swile + Sumeria Lunchflow connector ────────────────
  # Single service on port 8340; Sure connects to http://127.0.0.1:8340/api/v1
  services.sumeria-mitm = {
    enable           = true;
    exitNodeClients  = [ "100.112.22.60" ]; # nphone
    tokenFileGroup   = "for-sure";
  };

  services.for-sure = {
    enable                = true;
    port                  = 8340;
    apiKeyFile            = "/run/agenix/for-sure-api-key";
    swile.accountName     = "Swile";
    sumeria.tokenFile     = config.services.sumeria-mitm.tokenFile;
  };


  # ── PostgreSQL: sure_production database + sure_user ──────────────────────
  services.postgresql = {
    ensureDatabases = [ "sure_production" ];
    ensureUsers = [{
      name = "sure_user";
      # ensureDBOwnership requires db name == username; we grant ownership in sure-pg-setup
    }];

    # Allow sure_user to connect via TCP with scram-sha-256 password auth
    authentication = lib.mkAfter ''
      host  sure_production  sure_user  ${pgHost}/32  scram-sha-256
    '';
  };

  # Set sure_user password and DB ownership from agenix secret (ensurePasswordFile not
  # available in NixOS 25.11; use a oneshot service instead).
  systemd.services.sure-pg-setup = {
    description = "Set sure_user PostgreSQL password";
    # Wait for postgresql-setup.service so ensureUsers has created sure_user
    # before we ALTER it (otherwise: race; "role does not exist" on first boot).
    after    = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      password=$(cat /run/agenix/sure-pg-password)
      # psql variable interpolation (:'pw') requires stdin/-f input; it is silently
      # skipped with -c, producing "syntax error at or near :". Pipe via stdin.
      ${pkgs.postgresql}/bin/psql -v pw="$password" <<< "ALTER USER sure_user WITH PASSWORD :'pw';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE sure_production OWNER TO sure_user;"
    '';
  };

  # ── Sure application (native Nix, via sure-nix flake) ─────────────────────
  services.sure = {
    enable          = true;
    port            = backendPort;
    environmentFile = "/run/agenix/sure-app-env";
    databaseUrl     = "postgresql://sure_user@${pgHost}/sure_production";
    redisUrl        = "redis://${redisHost}:${toString redisPort}/2";
  };

  # ── Socket-activated idle sleep (rpi5/lib/socket-activate.nix) ──────────
  # Sure is the heaviest tier in the migration (~480 MB combined RSS for
  # web + worker). Rails cold start is ~30s → readyProbe against /up
  # (Rails 7.1+ health check) is required.
  #
  # sure-worker is sleepWith: Sidekiq stops alongside Puma. The companion
  # tweak to sumeria-sync-trigger below routes the path trigger through
  # sure-web (not sure-worker), so both tiers wake together; otherwise the
  # plan's "PartOf wakes the web" claim doesn't hold — PartOf only
  # propagates stops.
  services.socketActivate.sure = {
    enable    = true;
    realUnit  = "sure-web.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/up";
      expectStatus = 200;
      timeoutSec   = 60;
    };
    workers."sure-worker.service".policy = "sleepWith";
  };

  # ── Sure memory optimizations ──────────────────────────────────────────────
  # Reduce Sidekiq concurrency (personal app, no need for 3 threads) and limit
  # glibc malloc arenas to curb RSS on a 4 GB RPi5.
  # Note: jemalloc was tested but increases RSS on aarch64 + Ruby YJIT.
  systemd.services.sure-worker.environment = {
    RAILS_MAX_THREADS    = "1";
    SIDEKIQ_CONCURRENCY  = "1";  # default 5 — personal app only needs 1 worker thread
    MALLOC_ARENA_MAX     = "2";
    RUBY_YJIT_ENABLE     = "0";  # YJIT JIT-compiles into memory; not worth it for low-traffic personal app
  } // sureLlmEnv;
  systemd.services.sure-web.environment = {
    WEB_CONCURRENCY  = "0";  # single-process Puma (no forked workers) — saves ~80 MB on RPi5
    RAILS_MAX_THREADS = "3";  # default 5; 3 is plenty for single-user
    MALLOC_ARENA_MAX = "2";
    RUBY_YJIT_ENABLE = "0";
  } // sureLlmEnv;

  # sure-setup (migrations) must run after the password is set
  systemd.services.sure-setup = {
    after    = [ "sure-pg-setup.service" ];
    requires = [ "sure-pg-setup.service" ];
  };

  # ── Sumeria token → Sure sync trigger ──────────────────────────────────────
  # When the MITM captures new Sumeria tokens (file changes), automatically
  # trigger a Sure sync so balances/transactions update without manual action.
  # The MITM addon only writes on actual token change (not every request),
  # so this fires at most once per ~3h token rotation.
  systemd.paths.sumeria-sync-trigger = {
    description = "Watch Sumeria token file for changes";
    wantedBy    = [ "multi-user.target" ];
    pathConfig.PathModified = config.services.sumeria-mitm.tokenFile;
  };

  systemd.services.sumeria-sync-trigger = {
    description = "Trigger Sure sync after Sumeria token refresh";
    after       = [ "sure-web.service" "sure-worker.service" ];
    # Requires sure-web (not just sure-worker) so that under socket-activate
    # both tiers wake together — sure-worker has wantedBy=sure-web from the
    # socket-activate module, so pulling in web pulls in worker too.
    requires    = [ "sure-web.service" ];
    serviceConfig = {
      Type             = "oneshot";
      User             = config.services.sure.user;
      Group            = config.services.sure.group;
      WorkingDirectory = "${config.services.sure.package}/share/sure";
      EnvironmentFile  = config.services.sure.environmentFile;
    };
    environment = {
      RAILS_ENV          = "production";
      DATABASE_URL       = config.services.sure.databaseUrl;
      REDIS_URL          = config.services.sure.redisUrl;
      BUNDLE_FORCE_RUBY_PLATFORM = "1";
      HOME               = config.services.sure.dataDir;
    };
    script = ''
      echo "[sumeria-sync] Sumeria tokens changed, triggering Sure sync..."
      ${config.services.sure.package}/bin/sure-rails runner \
        'LunchflowItem.find_each { |item| item.sync_later }'
      echo "[sumeria-sync] Sync jobs queued; waiting 30s for Sidekiq to drain"
      # Keep this oneshot alive so sure-web + sure-worker don't idle-stop
      # before Sidekiq picks up and finishes the queued jobs (Sidekiq polls
      # Redis every 1s; 30s comfortably covers a Lunchflow sync).
      ${pkgs.coreutils}/bin/sleep 30
      echo "[sumeria-sync] Done"
    '';
  };

}
