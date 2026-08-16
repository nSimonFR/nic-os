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
# WRITABLE, on purpose. There used to be an nginx allowlist on :13346 that
# default-denied every write method, so the mirror was the only writer and the
# UI could not edit anything it owned. That has been removed at nSimon's
# request: `tailscale serve` points straight at the app again.
#
# What that costs, stated once so it is not a surprise: THE SYNC STILL WINS on
# anything it mirrors. Snapshots are upserted by (account, date), so a holding
# edited by hand is replaced at 06:23 the next morning. Accounts, positions,
# quantities and cost basis all come from Sure and go back to coming from Sure.
#
# What survives an edit: allocation targets (not in Sure at all), goals made by
# hand (only goals stamped "Mirrored from Sure" are pruned), addons, settings,
# and anything else the sync never writes.
{ config, pkgs, lib, ... }:
let
  stateDir = "/var/lib/wealthfolio-sync";
  internalPort = 13345; # wealthfolio.service — see wealthfolio.nix
in
{
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
