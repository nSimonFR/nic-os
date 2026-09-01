{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, apertureUrl, tailnetFqdn, ... }:
let
  # externalPort: where Tailscale Serve (→ :3333) and the socket-activate
  # proxy listen. backendPort: Sure's Puma binds here behind the proxy.
  externalPort = 13334;
  backendPort  = 13335;

  # rootVhostPort: the nginx vhost that gives Sure an origin of its own, where
  # the app sits at the root (see the vhost below). rootServePort: the tailnet
  # HTTPS port Tailscale Serve binds in front of it.
  rootVhostPort = 8093;
  rootServePort = 3850;

  # Headers both proxying locations on that vhost forward. The Host is the
  # LITERAL origin — not $host (which drops the port) and not $http_host
  # (client-controlled, which gixy fails the build on). Rails builds
  # request.base_url from it, and the browser's Origin header carries the port,
  # so without it every POST — starting with the login — would fail Rails' CSRF
  # origin check. Only tailscaled reaches this socket, and it only ever forwards
  # this one origin.
  fwdToSure = ''
    proxy_set_header Host ${tailnetFqdn}:${toString rootServePort};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  '';

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

  # ── A second door: Sure at an origin root, for clients that assume they own it ──
  # The 443 path-mux serves Sure under /sure, which every client that builds its
  # URLs from the *origin* rather than from the configured base gets wrong:
  #
  #   desktop app  — `normalize_server_url` (upstream desktop/src-tauri/src/servers.rs)
  #                  rebuilds what you type as scheme://host[:port] and THROWS THE
  #                  PATH AWAY, then health-checks {origin}/up demanding a literal
  #                  200 and afterwards navigates to {origin}/. Under the mux both
  #                  are Nextcloud, so it answers "Couldn't reach a Sure server at
  #                  that address".
  #   ActionCable  — the JS client connects to a root-absolute /cable regardless of
  #                  relative_url_root, so live updates 404 under the mux.
  #   mobile app   — concatenates (baseUrl + "/api/v1/…") and so DOES work under
  #                  the mux, but only if the sub-path is part of the saved
  #                  backend_url; drop it and every call lands at the root.
  #
  # So Sure gets an origin whose root IS Sure: /up answers, / lands in the app,
  # and anything else is forwarded with the /sure prefix prepended. Tailnet-only
  # — Tailscale funnels 443/8443/10000 and all three are allocated. The 443 /sure
  # mux is untouched and remains the URL to use from outside the tailnet.
  services.nginx.virtualHosts."sure-root" = {
    listen = [ { addr = "127.0.0.1"; port = rootVhostPort; ssl = false; } ];

    # Relative Location headers on the redirect below — otherwise nginx builds
    # it from its own listen socket and leaks http://127.0.0.1:8093.
    extraConfig = ''
      absolute_redirect off;
    '';

    locations = {
      # Answered here rather than proxied to Sure's own /sure/up. The desktop app
      # gives the health check 6 seconds (ureq timeout in
      # commands.rs::check_server) while a socket-activated cold start is ~30s, so
      # a real probe would fail every time Sure had idled out — which is most of
      # the time (idleSec=600). Nothing else lives on this origin, so "this origin
      # is Sure" is the whole question being asked; the answer does not depend on
      # Puma being awake. The navigation that follows wakes it like any other
      # request.
      "= /up" = {
        extraConfig = ''
          default_type text/plain;
          return 200 "OK\n";
        '';
      };

      # Where the desktop app navigates once the check passes. A redirect rather
      # than a proxy so the webview's address bar, and everything it resolves
      # relative to it, agree with the /sure prefix Rails emits.
      "= /" = { return = "301 /sure/"; };

      # Everything a root-assuming client asks for (/sessions/new, /api/v1/…,
      # /cable, /auth/…), re-rooted under /sure. The trailing slash on both sides
      # is what does it: nginx swaps the matched "/" for "/sure/". Longest-prefix
      # wins, so anything already carrying the prefix takes the block below and is
      # never doubled up.
      "/" = {
        proxyPass = "http://127.0.0.1:${toString externalPort}/sure/";
        proxyWebsockets = true;   # /cable
        extraConfig = fwdToSure;
      };

      # Same pass-through as the 443 mux — Rack::URLMap does the SCRIPT_NAME
      # strip itself, so /sure goes to the socket-activate port UNCHANGED and
      # every link Rails emits (all /sure-prefixed) lands back here.
      "/sure" = {
        proxyPass = "http://127.0.0.1:${toString externalPort}";
        proxyWebsockets = true;
        extraConfig = fwdToSure;
      };
    };
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
      # The script below waits for the sync to actually finish, which is well
      # past systemd's 90s default for a oneshot. Must exceed the in-script
      # deadline, or systemd would SIGTERM us mid-import — the exact failure
      # this unit is being fixed for.
      TimeoutStartSec  = "20min";
    };
    environment = {
      RAILS_ENV          = "production";
      DATABASE_URL       = config.services.sure.databaseUrl;
      REDIS_URL          = config.services.sure.redisUrl;
      BUNDLE_FORCE_RUBY_PLATFORM = "1";
      HOME               = config.services.sure.dataDir;
    };
    # This oneshot must outlive the sync it triggers: it holds sure-web up (and
    # sure-worker with it, via sleepWith), so when it exits the worker is torn
    # down — killing any Sidekiq job still in flight.
    #
    # It used to sleep a flat 30s, which was enough only while the Lunchflow
    # import was small. Once the connector started paging the full history
    # (~4100 transactions) the import ran past 30s, so every token-rotation sync
    # was SIGTERMed mid-import — and Sidekiq still marked the Sync `completed`,
    # so nothing retried and the missing rows were invisible. Observed: 243
    # transactions silently dropped, no error logged.
    #
    # So wait on the real signal instead of a magic number. `Sync.incomplete` is
    # pending+syncing and covers the child Account syncs the parent spawns, not
    # just the LunchflowItem sync. Bounded by a deadline so a stuck sync cannot
    # pin the heavy services up indefinitely.
    script = ''
      echo "[sumeria-sync] Sumeria tokens changed, triggering Sure sync..."
      ${config.services.sure.package}/bin/sure-rails runner '
        LunchflowItem.find_each { |item| item.sync_later }
        deadline = Time.current + 15.minutes
        # `rails runner` leaves the ActiveRecord query cache ENABLED, so polling
        # the same relation returns the first result for the life of the process
        # — the loop would never observe the sync finishing and would always run
        # to the deadline, pinning the heavy services up. Must be uncached.
        still_running = -> { Sync.uncached { Sync.incomplete.exists? } }
        sleep 2 while still_running.call && Time.current < deadline
        if still_running.call
          warn "[sumeria-sync] deadline reached with syncs still running"
        else
          puts "[sumeria-sync] all syncs complete"
        end
      '
      echo "[sumeria-sync] Done"
    '';
  };

  # The root origin (the vhost above). A registration of its own because
  # `public` is one-per-service and Sure's is the 443 mux entry — this is a
  # second route to the same app, not a second app. No tile: the Sure tile
  # already links to it, and the dashboard is read in a browser, where the mux
  # URL is the right one (it works from outside the tailnet; this does not).
  nic.services.sure-root = {
    backup     = [ "none" ];
    backupNote = "stateless — an nginx vhost; the app's state is registered on nic.services.sure";
    # nginx is infra that nixos-rebuild-safe deliberately leaves up, and Sure's
    # own units are listed on nic.services.sure.
    heavyUnits = [ ];

    public = {
      order   = 11;   # untiled; sits with sure (10), before wealthfolio (20)
      port    = rootServePort;
      backend = "http://127.0.0.1:${toString rootVhostPort}";
    };
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
      order   = 10;
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
          # display stays BLOCK. homepage only renders a mapping's
          # additionalField in its list branch, so the bracketed figures are
          # folded into the value string by the fetcher instead — which keeps
          # these tiles looking like every other one.
          # Net worth moved to the Wealthfolio tile — that is the one that
          # models the flat and the mortgage, so it is the only place the
          # number is actually complete. This tile answers what Sure is for:
          # what is left to spend, and how much has moved this month.
          mappings = [
            # Every value is pre-formatted text, brackets included — see the
            # display note above for why they cannot be additionalFields.
            #   Cash   total, then what is not tied up in the Livret A
            #   Spent  the month so far, then what is left of the budget
            #   Food   what has gone from the envelope, then what is left
            { field = "cash"; label = "Cash"; format = "text"; }
            { field = "spend"; label = "Spent"; format = "text"; }
            { field = "food"; label = "Food"; format = "text"; }
          ];
        };
      };
    };
  };
}
