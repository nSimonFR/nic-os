# hosts/rpi5/memos.nix
#
# Memos — self-hosted timeline of short notes (usememos/memos): the work
# journal's feed. Collectors and agents write to it over REST / MCP (`/mcp`),
# screenshots arrive as attachments, entries carry a location for the Map page.
#
# nixpkgs module; package from unstable because release-26.05 ships 0.25.3,
# older than MCP (0.27) and the Calendar/Map pages (0.31). Always-on, no socket
# activation: a Go binary at tens of MB, and MCP clients would pin it awake.
{ config, pkgs, unstablePkgs, tinyLlmGateUrl, ... }:
let
  internalPort = 13356;
  dataDir = "/var/lib/memos";
  # Attachments land in $MEMOS_DATA/assets (upstream default template); bound
  # from the HDD so restic covers them without a dump step.
  assetsDir = "/mnt/data/memos/assets";
in
{
  services.memos = {
    enable = true;
    package = unstablePkgs.memos;
    inherit dataDir;
    # Replaces the module default wholesale. MEMOS_MODE is gone upstream: the
    # SQLite file is memos_prod.db unless --demo.
    settings = {
      MEMOS_ADDR = "127.0.0.1";
      MEMOS_PORT = toString internalPort;
      MEMOS_DATA = dataDir;
      MEMOS_DRIVER = "sqlite";
      MEMOS_INSTANCE_URL = config.nic.services.memos.public.publicUrl;
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/data/memos 0750 memos memos -"
    "d ${assetsDir} 0750 memos memos -"
    "d /mnt/data/backups/memos 0750 memos memos -"
  ];

  systemd.services.memos = {
    unitConfig.RequiresMountsFor = [ assetsDir ];
    serviceConfig = {
      BindPaths = [ "${assetsDir}:${dataDir}/assets" ];
      # The module sets RestartSec but no Restart; earlyoom's SIGTERM exits 0.
      Restart = "always";
    };
  };

  systemd.services.memos-backup = {
    description = "Memos database backup";
    serviceConfig = { Type = "oneshot"; User = "memos"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      OUT=/mnt/data/backups/memos
      ${pkgs.sqlite}/bin/sqlite3 ${dataDir}/memos_prod.db ".timeout 60000" ".backup '$OUT/memos-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "$OUT/memos-$STAMP.db"
      ${pkgs.findutils}/bin/find "$OUT" -name "memos-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.memos-backup = {
    description = "Daily Memos backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 04:15:00"; Persistent = true; };
  };

  # One journal entry per day (workouts + Immich photos), after freereps-to-dawarich (03:30)
  # has put the day's routes into Dawarich. Root for `runuser -u postgres`.
  systemd.services.journal-daily = {
    description = "Daily journal entries in Memos (workouts + photos)";
    after = [ "memos.service" "postgresql.service" "freereps-to-dawarich.service" ];
    wants = [ "memos.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nicos-scripts}/bin/journal-daily";
      StateDirectory = "journal-daily";
      Environment = [
        "JOURNAL_STATE=/var/lib/journal-daily/days.json"
        "JOURNAL_DRY_RUN=0"
        "MEMOS_URL=http://127.0.0.1:${toString internalPort}"
        "MEMOS_TOKEN_FILE=${config.age.secrets.memos-token.path}"
        "PSQL_BIN=${config.services.postgresql.package}/bin/psql"
        "RUNUSER_BIN=${pkgs.util-linux}/bin/runuser"
        "GIT_BIN=${pkgs.git}/bin/git"
        # Side-project notes: `entire dispatch --local` as nsimon, one agent call per active day.
        "JOURNAL_DISPATCH_REPOS=/home/nsimon/nic-os"
        # The single "Nico's Family" tree (multi-tree mode keys it by id); I0009 = me.
        "GRAMPS_DB=/var/lib/gramps-web/data/grampsdb/6a51098a/sqlite.db"
        "GRAMPS_HOME_PERSON=I0009"
        "GRAMPS_URL=${config.services.gramps-web.baseUrl}"
        "JOURNAL_FONT=${pkgs.inter}/share/fonts/truetype/InterVariable.ttf"
        "AIRTRAIL_URL=${config.nic.services.airtrail.public.publicUrl}"
        "HA_DB=/var/lib/hass/home-assistant_v2.db"
        # Dawarich's Immich key reads assets only; memories and the memory-create job need this one.
        "IMMICH_ADMIN_KEY_FILE=${config.age.secrets.immich-api-key.path}"
        # One-line summary on top, by gpt-6-luna (cloud, ChatGPT plan): it sees the
        # visible text only — no links, no collapsed blocks, no family history.
        "TINY_LLM_GATE_URL=${tinyLlmGateUrl}"
      ];
      TimeoutStartSec = "45min";
    };
  };
  systemd.timers.journal-daily = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 04:30:00"; Persistent = true; };
  };

  nic.services.memos = {
    backup      = [ "unit" "mnt-data" ];
    backupUnits = [ "memos-backup.service" ];

    public = {
      # Alone on a seventh Apps row until it is given a place in one of the six.
      order         = 250;
      port          = 4020;
      backend       = "http://127.0.0.1:${toString internalPort}";
      authenticated = true;
      tile = {
        name        = "Memos";
        icon        = "memos.png";
        category    = "Apps";
        description = "Work journal";
      };
    };
  };
}
