# backups.nix — daily database backups to /mnt/data/backups/
# Each backup lands on the HDD so restic (storj-backup.nix) picks it up.
{ pkgs, ... }:
{
  # ── PostgreSQL (built-in NixOS module) ─────────────────────────────────
  services.postgresqlBackup = {
    enable = true;
    location = "/mnt/data/backups/postgresql";
    # forgejo adds itself in forgejo.nix; immich dumps its own DB to
    # /mnt/data/immich/backups. Everything else with a Postgres DB is listed
    # here so the nightly dump lands on /mnt/data and reaches Storj via restic.
    databases = [
      "affine"
      "dawarich"
      "sure_production"
      "nextcloud_production"
      "airtrail"
      "ghostfolio"
      "reactive_resume"
      "ryot"
    ];
    compression = "gzip";
    startAt = "*-*-* 03:00:00";
  };

  # ── SQLite backups ─────────────────────────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /mnt/data/backups/hass 0750 hass hass -"
    "d /mnt/data/backups/vaultwarden 0750 vaultwarden vaultwarden -"
    "d /mnt/data/backups/open-webui 0750 root root -"
    "d /mnt/data/backups/gramps-web 0750 gramps-web gramps-web -"
    "d /mnt/data/backups/papra 0750 papra papra -"
    "d /mnt/data/backups/beaverhabits 0750 beaverhabits beaverhabits -"
  ];

  systemd.services.hass-backup = {
    description = "Home Assistant database backup";
    serviceConfig = { Type = "oneshot"; User = "hass"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/hass/home-assistant_v2.db ".backup '/mnt/data/backups/hass/hass-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/hass/hass-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/hass -name "hass-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.hass-backup = {
    description = "Daily Home Assistant backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:00:00"; Persistent = true; };
  };

  # ── Open WebUI (SQLite) ─────────────────────────────────────────────────
  systemd.services.open-webui-backup = {
    description = "Open WebUI database backup";
    serviceConfig = { Type = "oneshot"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/open-webui/data/webui.db ".backup '/mnt/data/backups/open-webui/webui-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/open-webui/webui-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/open-webui -name "webui-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.open-webui-backup = {
    description = "Daily Open WebUI backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:30:00"; Persistent = true; };
  };

  # ── Papra (SQLite — Papra is libSQL-only, no Postgres) ──────────────────
  # Papra's metadata DB lives on the SSD; document FILES live on /mnt/data
  # (restic-covered directly). This atomic .backup lands the DB on /mnt/data too.
  # Runs as papra so it can read the DB regardless of whether papra.service is
  # awake (idle-sleep) — .backup only touches the file, not the running server.
  systemd.services.papra-backup = {
    description = "Papra database backup";
    serviceConfig = { Type = "oneshot"; User = "papra"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/papra/db.sqlite ".backup '/mnt/data/backups/papra/papra-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/papra/papra-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/papra -name "papra-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.papra-backup = {
    description = "Daily Papra backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:45:00"; Persistent = true; };
  };

  # ── BeaverHabits (SQLite — HABITS_STORAGE=DATABASE) ─────────────────────
  # Atomic .backup of habits.db onto /mnt/data so restic/storj picks it up.
  # Runs as beaverhabits (stable uid, not DynamicUser) so it can read the DB
  # whether or not the server is awake (idle-sleep) — .backup only touches the
  # file, not the running process.
  systemd.services.beaverhabits-backup = {
    description = "BeaverHabits database backup";
    serviceConfig = { Type = "oneshot"; User = "beaverhabits"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/beaverhabits/habits.db ".backup '/mnt/data/backups/beaverhabits/beaverhabits-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/beaverhabits/beaverhabits-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/beaverhabits -name "beaverhabits-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.beaverhabits-backup = {
    description = "Daily BeaverHabits backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 04:00:00"; Persistent = true; };
  };

  # ── Vaultwarden (file copy from built-in hot backup) ───────────────────
  systemd.services.vaultwarden-backup = {
    description = "Vaultwarden off-site backup";
    serviceConfig = { Type = "oneshot"; User = "vaultwarden"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.gzip}/bin/gzip -c /var/backup/vaultwarden/db.sqlite3 > "/mnt/data/backups/vaultwarden/vaultwarden-$STAMP.db.gz"
      ${pkgs.coreutils}/bin/cp /var/backup/vaultwarden/rsa_key.pem /mnt/data/backups/vaultwarden/
      ${pkgs.findutils}/bin/find /mnt/data/backups/vaultwarden -name "vaultwarden-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.vaultwarden-backup = {
    description = "Daily Vaultwarden backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:15:00"; Persistent = true; };
  };

  # ── Gramps Web (per-tree SQLite + media) ───────────────────────────────
  systemd.services.gramps-web-backup = {
    description = "Gramps Web family trees + media backup";
    serviceConfig = { Type = "oneshot"; User = "gramps-web"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      OUT=/mnt/data/backups/gramps-web
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/gramps-web/data/users.sqlite ".backup '$OUT/users-$STAMP.sqlite'"
      for tree in /var/lib/gramps-web/data/grampsdb/*/; do
        id=$(${pkgs.coreutils}/bin/basename "$tree")
        ${pkgs.sqlite}/bin/sqlite3 "$tree/sqlite.db" ".backup '$OUT/tree-$id-$STAMP.db'"
      done
      # tar -z shells out to `gzip` from PATH, which the unit's minimal PATH lacks
      # → use the absolute gzip like the sqlite dumps below.
      ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
        -cf "$OUT/media-$STAMP.tar.gz" -C /var/lib/gramps-web media
      ${pkgs.gzip}/bin/gzip -f "$OUT"/*-"$STAMP".sqlite "$OUT"/*-"$STAMP".db
      ${pkgs.findutils}/bin/find "$OUT" -mtime +7 -delete
    '';
  };

  systemd.timers.gramps-web-backup = {
    description = "Daily Gramps Web backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:45:00"; Persistent = true; };
  };
}
