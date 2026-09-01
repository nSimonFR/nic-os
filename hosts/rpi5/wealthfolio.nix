# hosts/rpi5/wealthfolio.nix
#
# Wealthfolio — private investment/portfolio tracker, web (server) edition.
# Single static Axum binary + prebuilt SPA, extracted from the upstream image by
# pkgs/services/wealthfolio.nix (which explains why it is not built from source).
#
# Storage is SQLite at /var/lib/wealthfolio/wealthfolio.db — no Postgres, so it
# reaches Storj via the dedicated dump unit in backups.nix, not
# `services.postgresqlBackup`. `/var/lib` is on the SSD, outside /mnt/data,
# which restic is the only thing covering: without that unit this DB would be
# unbacked from the day it landed (the Karakeep failure mode).
#
# Memory-constrained RPi5: measured RSS is ~12 MB idle and ~31 MB after a market
# data fetch — an order of magnitude below airtrail/beaverhabits — so it is NOT
# put behind socket-activate idle sleep. A proxy would cost more (a resident
# systemd-socket-proxyd, a wake latency on every first request, a readiness
# probe to get wrong) than the ~12 MB it would reclaim, and the 4-hourly broker
# sync scheduler wants to actually run.
#
# THE AI ASSISTANT IS DB STATE, NOT CONFIG. There is no WF_AI_* env knob: the
# whole provider config lives in one `app_settings` row (`ai_provider_settings`)
# written through PUT /api/v1/ai/providers/settings. Ours points the built-in
# "openai" provider at tiny-llm-gate (customUrl http://127.0.0.1:4001/v1) with
# selectedModel gpt-5.6. That row also carries a `modelCapabilityOverrides`
# entry that is load-bearing and NOT reproducible by a rebuild:
#
#   {"gpt-5.6": {"tools": true}}
#
# Wealthfolio decides tool support from a model catalog baked into the server
# binary (gpt-5.4 / -mini / -nano only). Any model it does not recognise —
# which is every model this gate actually serves — resolves to tools=false, so
# the server sends NO tool definitions and the assistant answers portfolio
# questions with "I don't have access to your asset allocation with the current
# model. Please switch to a tool-enabled model using the gear icon". The gear
# icon is that override; it is per (provider, modelId), so it must be re-set
# after a DB restore and again for any new selectedModel:
#
#   curl -sb <cookiejar> -X PUT http://127.0.0.1:13345/api/v1/ai/providers/settings \
#     -H 'Content-Type: application/json' \
#     -d '{"providerId":"openai","modelCapabilityOverride":
#          {"modelId":"gpt-5.6","overrides":{"tools":true}}}'
#
# KNOWN-BROKEN, ACCEPTED 2026-08-20: asset-allocation questions specifically.
# Through the gate's codex surface, gpt-5.6 fills every OPTIONAL string
# parameter with "" instead of omitting it — reproducible outside Wealthfolio
# with a bare curl to :4001, and NOT the gate's doing (it forwards the tool
# schema verbatim and does not set `strict`). Claude, gemma4:e4b and
# qwen3.6:35b-a3b all omit them correctly.
#
# Every other tool tolerates that: get_performance with accountId "" still
# returns the aggregate, get_net_worth ignores a blank startDate. But
# `get_asset_allocation` reads a present-but-empty categoryId/taxonomyId as a
# DRILL-DOWN request, looks up category "", and returns
# `{holdings: [], totalValue: 0.0, taxonomyName: "Unknown"}` with
# success: true — so the assistant reports "€0 in holdings" rather than an
# error. Deterministic, twice out of two runs.
#
# The fix belongs in tiny-llm-gate (drop "" args not in the schema's `required`
# on the codex response path) and is deliberately NOT taken: routing the
# assistant at Claude instead is a dead end (claude-opus-5 rejects the
# `temperature` Wealthfolio always sends, and third-party OAuth draws on
# unfunded Extra Usage), and a local model gets the groupBy enum wrong. Use the
# Allocation page for allocation; the assistant is trustworthy on net worth,
# performance, activities and health.
#
# AUTH IS NOT OPTIONAL HERE. Wealthfolio serves the whole portfolio unauth'd
# unless WF_AUTH_PASSWORD_HASH is set; the tailnet is not a trust boundary worth
# betting real holdings on. The hash (argon2id PHC string) and WF_SECRET_KEY —
# which encrypts stored broker/API credentials — both come from the agenix env
# file so neither lands in the world-readable Nix store.
{ config, pkgs, lib, ... }:
let
  wealthfolio = pkgs.callPackage ../../pkgs/services/wealthfolio.nix { };

  internalPort = 13345; # Axum bind (real backend, localhost only)
  # External tailnet HTTPS port: declared once in nic.services.wealthfolio.public
  # below, which also derives publicUrl.
in
{
  users.users.wealthfolio = {
    isSystemUser = true;
    group = "wealthfolio";
    description = "Wealthfolio portfolio tracker";
  };
  users.groups.wealthfolio = { };

  systemd.services.wealthfolio = {
    description = "Wealthfolio investment tracker";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      WF_LISTEN_ADDR = "127.0.0.1:${toString internalPort}";
      WF_DB_PATH = "/var/lib/wealthfolio/wealthfolio.db";
      # Default is the relative path "dist", resolved against CWD — point it at
      # the store copy instead of depending on WorkingDirectory.
      WF_STATIC_DIR = "${wealthfolio}/share/wealthfolio/dist";
      WF_ADDONS_DIR = "/var/lib/wealthfolio/addons";
      # Tailscale Serve terminates TLS in front of us, so the session cookie
      # must still be marked Secure even though our own listener is plain HTTP.
      WF_COOKIE_SECURE = "true";
      WF_AUTH_REQUIRED = "true";
      # NOT decoration: WF_CORS_ALLOW_ORIGINS defaults to "*", and the server
      # PANICS on startup rather than serving with a wildcard once auth is on
      # ("cannot be \"*\" when authentication is enabled"). Found by running the
      # binary with the real env before this landed; without it the unit would
      # have crash-looped on the first rebuild.
      WF_CORS_ALLOW_ORIGINS = config.nic.services.wealthfolio.public.publicUrl;
      # Default is 60 minutes. There is no refresh token — instead the cookie is
      # re-issued on any request past half the TTL, so an open tab never
      # expires, but the installed PWA (the only way onto this from a phone;
      # the native iOS app cannot point at a self-hosted server) hits a hard
      # 401 after an hour of not being opened. 30 days turns "log in every
      # time" into "log in monthly". No upper bound in config.rs.
      WF_AUTH_TOKEN_TTL_MINUTES = "43200";
      # Agent access: the /mcp endpoint, off by default. Guarded by its own
      # bearer PAT with its own scope set — a session cookie is rejected there
      # and a PAT is rejected on /api/v1, so this grants nothing to the browser
      # and nothing to the sync.
      #
      # The PAT is minted READ-ONLY (accounts/holdings/performance/activities/
      # planning/health/classification). Sure is the writer; an agent that could
      # write here would be writing to a mirror that the next sync overwrites.
      WF_MCP_ENABLED = "true";
      # Host validation off: rmcp's default allowlist is loopback-only and
      # Hermes reaches this through the tailnet name. Safe because /mcp is
      # PAT-guarded, and browsers cannot attach an Authorization header
      # cross-site, so DNS rebinding buys nothing.
      WF_MCP_AUDIT_ENABLED = "true";
    };

    serviceConfig = {
      ExecStart = lib.getExe wealthfolio;
      # WF_SECRET_KEY + WF_AUTH_PASSWORD_HASH
      EnvironmentFile = "/run/agenix/wealthfolio-env";
      User = "wealthfolio";
      Group = "wealthfolio";
      StateDirectory = "wealthfolio";
      StateDirectoryMode = "0700";
      WorkingDirectory = "/var/lib/wealthfolio";
      Restart = "on-failure";
      RestartSec = "10s";

      # Hardening. The binary is static musl and touches nothing but its state
      # directory, the network (market data) and the clock.
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.wealthfolio = {
    backup = [ "unit" ];
    backupUnits = [ "wealthfolio-backup.service" ]; # backups.nix
    heavyUnits = [ "wealthfolio.service" ];
    heavyPriority = 90;

    public = {
      order = 20; # the other money tile, right after Sure (10)
      port = 3700;
      backend = "http://127.0.0.1:${toString internalPort}";
      tile = {
        name = "Wealthfolio";
        icon = "https://cdn.jsdelivr.net/gh/wealthfolio/wealthfolio@v3.6.3/apps/frontend/public/logo.svg";
        category = "Apps";
        description = "Investment portfolio tracker";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/wealthfolio";
          refreshInterval = 3600000;
          # display stays BLOCK. homepage only renders a mapping's
          # additionalField in its list branch, so the bracketed figures are
          # folded into the value string by the fetcher instead — which keeps
          # these tiles looking like every other one.
          # No gain AMOUNT here on purpose. In HOLDINGS tracking mode — which
          # is what the Sure mirror uses — Wealthfolio returns
          # `amountStatus: "unavailable"`, because external cash flows are
          # inferred from snapshot deltas rather than observed, and a transfer
          # out of an account is indistinguishable from a loss. Deriving one
          # anyway produced -€21k for a month that returned +3.75%. The percent
          # is the app's own `returns.valueReturn` and is trustworthy.
          #
          # `format = "text"` and NOT "percent": homepage's percent formatter is
          # Intl percent-style applied to (value / 100), so the two cancel and it
          # renders the number unchanged at zero decimal places — the API's
          # 0.0224 displayed as "0%". The fetcher formats to two places and the
          # suffix supplies the sign.
          mappings = [
            # Carries the investments total — net worth is mostly the flat, so
            # the bracket says how much of it is actually market-exposed.
            { field = "net_worth"; label = "Net Worth"; format = "text"; }
            # Carries "(+€9,783)" — market value less cost basis.
            { field = "invested"; label = "Invested"; format = "text"; }
            # Carries "2.24% (+€881)" — the euro figure is that percentage
            # restated against the portfolio value 30 days ago, not a separate
            # claim. See fetch_wealthfolio.
            { field = "return_30d"; label = "30d"; format = "text"; }
          ];
        };
      };
    };
  };
}
