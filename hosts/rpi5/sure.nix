{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, apertureUrl, tailnetFqdn, telegramChatId, ... }:
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
    # "auto" (gemma4:e4b) had 55-80% JSON validation failure rate; the codex
    # tiers produce valid JSON in both strict json_schema and json_object modes
    # at the cost of higher token usage. gpt-6 works here too (verified
    # 2026-09-06) but ate the plan quota too fast — see the note on the gate.
    OPENAI_MODEL        = "gpt-5.6";
    OPENAI_ACCESS_TOKEN = "unused"; # real auth lives in the gate's codex OAuth
    # The 2048 default leaves only 1280 input tokens, but the auto_categorize
    # prompt (full category list) needs ~1352 → categories were never assigned.
    # gpt-5.6 has ample context; 8192 gives 7424 input budget.
    LLM_CONTEXT_WINDOW  = "8192";
  };

  # Shared shape for the oneshots that drive a Sure sync from OUTSIDE Rails — the
  # Sumeria token refresh, and the daily account sync. Both have the same hard
  # requirement, which is why they are one function rather than two units:
  #
  # The oneshot holds sure-web up (and sure-worker with it, via sleepWith), so
  # when it exits the worker is torn down — killing any Sidekiq job still in
  # flight. It used to sleep a flat 30s, which was enough only while the
  # Lunchflow import was small. Once the connector started paging the full
  # history (~4100 transactions) the import ran past 30s, so every sync was
  # SIGTERMed mid-import — and Sidekiq still marked the Sync `completed`, so
  # nothing retried and the missing rows were invisible. 243 transactions were
  # silently dropped with no error logged (nic-os PR#588).
  #
  # So wait on the real signal, not a magic number. `Sync.incomplete` is
  # pending+syncing and covers the child Account syncs the parent spawns, not
  # just the item sync. Bounded by a deadline so a stuck sync cannot pin the
  # heavy services up indefinitely; TimeoutStartSec must exceed that deadline or
  # systemd's 90s oneshot default reintroduces the very kill being fixed.
  syncTrigger = { description, tag, enqueue }: {
    inherit description;
    after = [ "sure-web.service" "sure-worker.service" ];
    # Requires sure-web (not just sure-worker) so that under socket-activate both
    # tiers wake together — sure-worker has wantedBy=sure-web from the
    # socket-activate module, so pulling in web pulls in worker too.
    requires = [ "sure-web.service" ];
    serviceConfig = {
      Type             = "oneshot";
      User             = config.services.sure.user;
      Group            = config.services.sure.group;
      WorkingDirectory = "${config.services.sure.package}/share/sure";
      EnvironmentFile  = config.services.sure.environmentFile;
      TimeoutStartSec  = "20min";
    };
    environment = {
      RAILS_ENV          = "production";
      DATABASE_URL       = config.services.sure.databaseUrl;
      REDIS_URL          = config.services.sure.redisUrl;
      BUNDLE_FORCE_RUBY_PLATFORM = "1";
      HOME               = config.services.sure.dataDir;
    };
    script = ''
      echo "[${tag}] triggering Sure sync..."
      ${config.services.sure.package}/bin/sure-rails runner '
        ${enqueue}
        deadline = Time.current + 15.minutes
        # `rails runner` leaves the ActiveRecord query cache ENABLED, so polling
        # the same relation returns the first result for the life of the process
        # — the loop would never observe the sync finishing and would always run
        # to the deadline, pinning the heavy services up. Must be uncached.
        still_running = -> { Sync.uncached { Sync.incomplete.exists? } }
        sleep 2 while still_running.call && Time.current < deadline
        if still_running.call
          warn "[${tag}] deadline reached with syncs still running"
        else
          puts "[${tag}] all syncs complete"
        end
      '
      echo "[${tag}] Done"
    '';
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

    # Sumeria tokens are static session headers captured off the phone by
    # sumeria-mitm; they expire in ~3h and there is no refresh flow — renewing
    # them REQUIRES a human enabling the RPi5 exit node and opening the app. So
    # the 401 alert is not a nicety, it is the only thing that closes the loop.
    #
    # It was dead: for-sure's sendTelegram() returns early unless BOTH of these
    # are set, and neither ever was, so `getAccounts` threw its "tokens expired"
    # error into the journal and told nobody. Sure surfaces it only as
    # `Lunch Flow API: Unexpected response - Code: 500`, buried in sure-worker.
    # Tokens lapsed 2026-09-08 08:42 and no Sumeria transaction synced for 2
    # days without a single notification. The agenix secret was already
    # group-readable by for-sure (secrets.nix: group "for-sure", mode 0440) —
    # only these two lines were missing.
    telegram.botTokenFile = config.age.secrets.telegram-bot-token.path;
    telegram.chatId       = toString telegramChatId;
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

  # ── Keep Sure awake while Sidekiq still has work ─────────────────────────────
  # `sleepWith` above ties sure-worker's lifetime to the WEB tier: the proxy
  # exits after idleSec without an HTTP connection, StopWhenUnneeded stops
  # sure-web, and PartOf takes the worker with it — with Sidekiq's queue depth
  # invisible to all of it. So the worker gets killed mid-backlog and only
  # revives when a human next opens the UI.
  #
  # That is what broke auto-categorization for 8 days from 2026-09-02: a rule
  # run left ~950 jobs queued (~7.6h of continuous LLM work at ~40s/job) while
  # the worker was awake 2-11 minutes per wake, once or twice a day — about
  # 7 min/day. Categories simply stopped; nothing was wrong with the LLM, the
  # model, the context budget or the rule.
  #
  # No new systemd machinery is needed to fix it: --exit-idle-time restarts on
  # every connection, so one request inside each idle window holds the whole
  # tier up. This makes that request ONLY while a queue is non-empty, so idle
  # sleep is untouched whenever there is genuinely nothing to do. Reordering
  # Sidekiq's queues was the other candidate and would not have worked —
  # weights are a per-fetch shuffle, not priorities, and the constraint was
  # uptime, not order.
  systemd.services.sure-drain-keepalive = {
    description = "Hold Sure awake while Sidekiq has queued work";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nicos-scripts}/bin/sure-drain-keepalive";
      Environment = [
        "REDIS_CLI_BIN=${pkgs.redis}/bin/redis-cli"
        "CURL_BIN=${pkgs.curl}/bin/curl"
        "WAKE_URL=http://127.0.0.1:${toString externalPort}/sure/up"
      ];
    };
  };
  systemd.timers.sure-drain-keepalive = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      # Must stay comfortably inside idleSec (600s) or the proxy exits between
      # pokes and the hold does not hold.
      OnUnitActiveSec = "4m";
    };
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

  systemd.services.sumeria-sync-trigger = syncTrigger {
    description = "Trigger Sure sync after Sumeria token refresh";
    tag         = "sumeria-sync";
    enqueue     = "LunchflowItem.find_each { |item| item.sync_later }";
  };

  # ── Daily account sync (restores Sure's own dead cron) ───────────────────────
  # Sure schedules its daily sync itself: AutoSyncScheduler registers the
  # `sync_all_accounts` sidekiq-cron entry from Setting.auto_sync_time (13:50
  # Europe/Paris here) running SyncAllJob. But sidekiq-cron only fires while the
  # WORKER PROCESS is up, and under socket-activate the worker is awake ~10
  # minutes a day, whenever someone opens the UI. It therefore essentially never
  # coincides with 13:50, and `sync_all_accounts` last fired 2026-09-02 — nine
  # days before this was written. Every other Sure cron scheduled outside that
  # accidental window has been dead since socket activation landed (~2026-07-02):
  # clean_data, clean_debug_log_entries, clean_inactive_families,
  # run_security_health_checks and import_market_data all last fired Jul 1-2, and
  # generate_insights has never run at all. Only the hourly/15-min entries look
  # healthy, and only because a wake happens to catch one of their slots.
  #
  # Consequence for the thing that prompted this: Sumeria is NOT on the hourly
  # path (SyncHourlyJob's HOURLY_SYNCABLES is CoinstatsItem only), so the dead
  # daily cron was its only automatic sync.
  #
  # Deliberately does NOT try to make sidekiq-cron fire. Waking Sure just before
  # 13:50 would work only in summer: AutoSyncScheduler converts the Paris time to
  # a fixed UTC cron (`50 11 * * *`) and only recomputes it when the setting is
  # re-saved, so the entry drifts an hour against local time at every DST change
  # while an OnCalendar timer would not. Enqueueing SyncAllJob directly is the
  # same work with no clock to keep in agreement.
  #
  # Persistent so a sync missed while the Pi was down or rebuilding runs on the
  # next boot rather than being skipped until tomorrow.
  systemd.services.sure-daily-account-sync = syncTrigger {
    description = "Daily Sure sync of all accounts";
    tag         = "sure-daily-sync";
    enqueue     = "SyncAllJob.perform_later";
  };
  systemd.timers.sure-daily-account-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Local time, so it tracks Europe/Paris DST — matching the intent of
      # Setting.auto_sync_time, which the stored UTC cron does not.
      OnCalendar = "13:50";
      Persistent = true;
    };
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
