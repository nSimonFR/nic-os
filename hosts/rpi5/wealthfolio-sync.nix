# hosts/rpi5/wealthfolio-sync.nix
#
# Sure -> Wealthfolio mirror, plus the read-only wall that makes the mirror the
# only writer.
#
# Sure stays the single source of truth. Wealthfolio is a nicer set of charts
# over the same holdings, so everything in it is derived and nothing there
# should ever be edited by hand — an edit would survive exactly until the next
# sync and then vanish, which is the worst kind of data loss because it looks
# like it worked.
#
# TWO PORTS, TWO POSTURES. wealthfolio.service binds 127.0.0.1:13345. Until now
# `tailscale serve` pointed 3700 straight at it; it now points at an nginx vhost
# that DENIES writes, and the sync connects to 13345 directly. Enforcement for
# the browser, full access for the syncer, and no second credential to manage.
#
# The allowlist is an ALLOWLIST, not a denylist. There are ~130 non-GET routes
# under /api/v1, and enumerating them to deny is both fragile and fails OPEN on
# upgrade — which matters here because the pinned image is 3.6.3 while upstream
# is already past 3.7. Default-deny every write method, then re-admit the
# handful of POSTs that are reads wearing a POST (search and `/query` endpoints
# that take a filter body). Anything upstream adds later is denied until
# someone looks at it.
#
# The allowed set was taken from an actual SPA session against the running
# server, not from reading the frontend and hoping.
{ config, pkgs, lib, ... }:
let
  stateDir = "/var/lib/wealthfolio-sync";
  internalPort = 13345; # wealthfolio.service — see wealthfolio.nix
  proxyPort = 13346; # nginx read-only vhost; tailscale serve → here
in
{
  # ── The read-only front ────────────────────────────────────────────────────
  services.nginx.virtualHosts."wealthfolio-readonly" = {
    listen = [ { addr = "127.0.0.1"; port = proxyPort; } ];

    locations = {
      # Login and logout must work, or nobody can read anything.
      "= /api/v1/auth/login".proxyPass = "http://127.0.0.1:${toString internalPort}";
      "= /api/v1/auth/logout".proxyPass = "http://127.0.0.1:${toString internalPort}";

      # POST-shaped reads. These take a filter/date-range body, which is why
      # they are POSTs at all; none of them mutates.
      "~ ^/api/v1/.*/query$".proxyPass = "http://127.0.0.1:${toString internalPort}";
      "~ ^/api/v1/(activities|spending/cash-activities)/search$".proxyPass =
        "http://127.0.0.1:${toString internalPort}";
      "~ ^/api/v1/performance/".proxyPass = "http://127.0.0.1:${toString internalPort}";
      "~ ^/api/v1/spending/(report|insight|event-spending-summaries)$".proxyPass =
        "http://127.0.0.1:${toString internalPort}";
      "= /api/v1/market-data/quotes/latest".proxyPass =
        "http://127.0.0.1:${toString internalPort}";
      # WRITABLE, deliberately — the two things the mirror does not own.
      #
      # Allocation targets are not in Sure at all, so nothing here can overwrite
      # them. Goals are mirrored, but the sync only prunes goals it created
      # (matched on the "Mirrored from Sure" description), so one made by hand
      # in the UI survives every run. Everything else on /api/v1 stays read-only:
      # a holding edited here would live until the next sync and then vanish.
      #
      # Addons are here too, so they can be installed from the UI. An addon is
      # arbitrary JavaScript running in the session, which sounds worse than it
      # is HERE: it is confined to a sandboxed iframe, and its API calls go back
      # through this same proxy — so an addon cannot write a holding either. It
      # gets exactly the surface below, no more.
      "~ ^/api/v1/(allocation-targets|goals|addons)".proxyPass =
        "http://127.0.0.1:${toString internalPort}";

      # portfolio/update fires unprompted on every authenticated page load and
      # only enqueues a quote fetch — it rewrites derived valuation tables, never
      # a holding. Allowed, so prices stay live between syncs; denying it would
      # leave the UI showing yesterday's marks until the 06:23 timer.
      "= /api/v1/portfolio/update".proxyPass = "http://127.0.0.1:${toString internalPort}";

      # Everything else: reads pass, writes are refused.
      "/" = {
        proxyPass = "http://127.0.0.1:${toString internalPort}";
        extraConfig = ''
          limit_except GET HEAD OPTIONS {
            deny all;
          }
        '';
      };
    };
  };

  # ── The sync ───────────────────────────────────────────────────────────────
  users.users.wealthfolio-sync = {
    isSystemUser = true;
    group = "wealthfolio-sync";
    description = "Sure -> Wealthfolio mirror";
  };
  users.groups.wealthfolio-sync = { };

  systemd.services.wealthfolio-sync = {
    description = "Mirror Sure holdings into Wealthfolio";
    after = [ "wealthfolio.service" "postgresql.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    # No wantedBy: the timer is the only thing that should start this. A run on
    # every activation would race a mid-rebuild wealthfolio restart.

    environment = {
      # 13345 directly, NOT the :13346 read-only vhost — the syncer is the one
      # writer this whole arrangement exists to permit.
      WF_URL = "http://127.0.0.1:${toString internalPort}";
      SURE_DB = "sure_production";
      STATE_DIR = stateDir;
      RUNUSER_BIN = "${pkgs.util-linux}/bin/runuser";
      PSQL_BIN = "${config.services.postgresql.package}/bin/psql";
      # The module defaults to dry_run; the unit is the thing that opts in.
      DRY_RUN = "0";
      # Latest date only. Set to a date once, by hand, for the initial history
      # load — then put it back, or every run re-imports 500 dates per account.
      BACKFILL_FROM = "";
    };

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nicos-scripts}/bin/sure-to-wealthfolio";
      # root, because reading Sure's DB goes through `runuser -u postgres` (peer
      # auth on the local socket) — sure-pg-password is postgres-owned and the
      # sync neither has nor needs it.
      User = "root";
      StateDirectory = "wealthfolio-sync";
      EnvironmentFile = "/run/agenix/wealthfolio-sync-env"; # WF_PASSWORD
    };
  };

  systemd.timers.wealthfolio-sync = {
    description = "Daily Sure -> Wealthfolio mirror";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # After Sure's own overnight refresh, before anyone looks at it.
      OnCalendar = "*-*-* 06:23:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
