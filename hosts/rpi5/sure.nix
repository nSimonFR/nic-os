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
    # Use gpt-5.6 directly for reliable JSON output in merchant categorization.
    # "auto" (gemma4:e4b) had 55-80% JSON validation failure rate; gpt-5.6
    # produces valid JSON in both strict json_schema and json_object modes
    # (verified against the gate) at the cost of higher token usage.
    OPENAI_MODEL        = "gpt-5.6";
    OPENAI_ACCESS_TOKEN = "unused"; # real auth lives in codex-proxy OAuth
    # The 2048 default leaves only 1280 input tokens, but the auto_categorize
    # prompt (full category list) needs ~1352 → categories were never assigned.
    # gpt-5.6 has ample context; 8192 gives 7424 input budget.
    LLM_CONTEXT_WINDOW  = "8192";
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
  nic.pgRole.sure = {
    db           = "sure_production";
    user         = "sure_user";
    passwordFile = "/run/agenix/sure-pg-password";
    description  = "Set sure_user PostgreSQL password";
  };

  # ── Sure application (native Nix, via sure-nix flake) ─────────────────────
  services.sure = {
    enable          = true;
    port            = backendPort;
    environmentFile = "/run/agenix/sure-app-env";
    databaseUrl     = "postgresql://sure_user@${pgHost}/sure_production";
    redisUrl        = "redis://${redisHost}:${toString redisPort}/2";
    # Stop the AI auto-categorizer from labeling internal transfers
    # (kind=funds_movement) — it mislabeled Livret A moves as "Investment
    # Contributions". Optional source patch, enabled here per-deployment.
    #
    # coinstats-balance-holdings-fallback: keep CoinStats-synced crypto wallets
    # from collapsing to $0 when the CoinStats free-tier credit limit is reached
    # (every wallet endpoint 406s → zero-balance snapshot → reverse materializer
    # sets cash = -holdings). Anchors the account to its preserved holdings value
    # instead. See nSimonFR/sure-nix#17.
    #
    # editable-linked-transaction-date: re-enable editing the date of
    # connector-imported (linked?) transactions. Upstream disables the date
    # field on any entry with an external_id, which is all of them here; the
    # lock is UI-only (server permits :date and marks the entry user_modified
    # so sync won't overwrite it). See nSimonFR/sure-nix#18.
    patchFlags = {
      auto-categorize-skip-transfers = true;
      coinstats-balance-holdings-fallback = true;
      editable-linked-transaction-date = true;
    };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ──────────
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
      # App mounts under /sure (Rack::URLMap, keyed on RAILS_RELATIVE_URL_ROOT
      # set on sure-web below), so the root /up now 404s — probe /sure/up.
      url          = "http://127.0.0.1:${toString backendPort}/sure/up";
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
    RAILS_RELATIVE_URL_ROOT = "/sure";  # match sure-web so job/mailer URLs prefix /sure
  } // sureLlmEnv;
  systemd.services.sure-web.environment = {
    WEB_CONCURRENCY  = "0";  # single-process Puma (no forked workers) — saves ~80 MB on RPi5
    RAILS_MAX_THREADS = "3";  # default 5; 3 is plenty for single-user
    MALLOC_ARENA_MAX = "2";
    RUBY_YJIT_ENABLE = "0";
    # Serve under /sure on the 443 path-mux (front-proxy.nix). sure-nix's
    # config.ru mounts the app via Rack::URLMap when this is set, so redirects
    # and path-helpers prefix /sure (assets already do via relative_url_root).
    # The proxy passes /sure through UNCHANGED — URLMap does the internal strip.
    RAILS_RELATIVE_URL_ROOT = "/sure";
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

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.sure = {
    backup            = [ "postgres" ];
    postgresDatabases = [ "sure_production" ];
    heavyUnits        = [ "sure-worker.service" "sure-web.service" ];
    heavyPriority     = 70;

    # Passed through the path-mux UNCHANGED (no prefix strip): config.ru mounts
    # the app under RAILS_RELATIVE_URL_ROOT=/sure via Rack::URLMap, which does the
    # SCRIPT_NAME strip itself. Backend is the socket-activate port, so a request
    # wakes Puma.
    public = {
      order   = 30;
      port    = 443;
      backend = "http://127.0.0.1:13334";
      proxied = true;
      muxPath = "/sure";
      tile = {
        name        = "Sure";
        icon        = "maybe.svg";
        category    = "Apps";
        description = "Personal finance";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/sure";
          refreshInterval = 3600000;
          # Net worth moved to the Wealthfolio tile — that is the one that
          # models the flat and the mortgage, so it is the only place the
          # number is actually complete. This tile answers what Sure is for:
          # what is left to spend, and how much has moved this month.
          mappings = [
            { field = "cash"; label = "Cash"; format = "number"; prefix = "€"; }
            { field = "spend"; label = "Spent"; format = "number"; prefix = "€"; }
            {
              field = "budget"; label = "Budget"; format = "number"; prefix = "€";
              # What is still unspent; negative means over budget.
              additionalField = { field = "budget_left"; format = "text"; };
            }
          ];
        };
      };
    };
  };
}
