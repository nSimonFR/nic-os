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
      order = 35; # immediately after Sure (30) — the two finance tiles read together
      port = 3700;
      # The read-only nginx vhost from wealthfolio-sync.nix, NOT the app's own
      # port: everything reachable from the tailnet goes through the write
      # refusal. The sync connects to internalPort directly.
      backend = "http://127.0.0.1:13346";
      tile = {
        name = "Wealthfolio";
        icon = "https://cdn.jsdelivr.net/gh/wealthfolio/wealthfolio@v3.6.3/apps/frontend/public/logo.svg";
        category = "Apps";
        description = "Investment portfolio tracker";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/wealthfolio";
          refreshInterval = 3600000;
          # display=list, NOT the default block: homepage's block renderer draws
          # `<Block label value />` and ignores additionalField entirely — the
          # bracketed figures simply never appeared. Only the list branch of
          # customapi/component.jsx renders a mapping's additionalField.
          display = "list";
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
            { field = "net_worth"; label = "Net Worth"; format = "number"; prefix = "€"; }
            {
              field = "invested"; label = "Invested"; format = "number"; prefix = "€";
              # Rendered next to the value by homepage, hence the brackets and
              # sign live in the string the fetcher produces.
              additionalField = { field = "gain"; format = "text"; };
            }
            { field = "return_30d"; label = "30d"; format = "text"; suffix = "%"; }
          ];
        };
      };
    };
  };
}
