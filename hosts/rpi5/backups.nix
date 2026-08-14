# backups.nix — daily database backups to /mnt/data/backups/
# Each backup lands on the HDD so restic (storj-backup.nix) picks it up.
{ pkgs, ... }:
{
  # ── PostgreSQL (built-in NixOS module) ─────────────────────────────────
  # `databases` is NOT listed here. It is derived from
  # `nic.services.<name>.postgresDatabases` (hosts/rpi5/lib/service-registration.nix),
  # declared in each service's own module.
  #
  # The hand-maintained list this replaced had drifted in both directions: it
  # dumped `ghostfolio`, left over from a service no module in the repo defines
  # any more, while Karakeep — which does have state — was absent because SQLite
  # services had no representation here at all. Dropping ghostfolio stops the
  # nightly dump; the database itself is still live (25 MB, effectively static)
  # and its last dump stays on /mnt/data, exactly as paperless_production's did
  # when that service was retired. Drop the database when you're satisfied
  # nothing wants it.
  services.postgresqlBackup = {
    enable = true;
    location = "/mnt/data/backups/postgresql";
    compression = "gzip";
    startAt = "*-*-* 03:00:00";
  };

  # ── SQLite backups ─────────────────────────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /mnt/data/backups/hass 0750 hass hass -"
    "d /mnt/data/backups/vaultwarden 0750 vaultwarden vaultwarden -"
    "d /mnt/data/backups/gramps-web 0750 gramps-web gramps-web -"
    "d /mnt/data/backups/papra 0750 papra papra -"
    "d /mnt/data/backups/beaverhabits 0750 beaverhabits beaverhabits -"
    "d /mnt/data/backups/karakeep 0750 karakeep karakeep -"
    "d /mnt/data/backups/wealthfolio 0750 wealthfolio wealthfolio -"
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

  # ── Wealthfolio (SQLite — the server edition is SQLite-only) ────────────
  # Everything lives at /var/lib/wealthfolio on the SSD, outside /mnt/data, so
  # restic (storj-backup.nix, which backs up /mnt/data and nothing else) would
  # never see it. This atomic .backup is the only path the portfolio takes to
  # Storj; nic.services.wealthfolio.backup pins it as the answer and
  # lib/service-registration.nix asserts the unit exists.
  #
  # The WAL matters here: the server holds the DB open continuously (it is not
  # socket-idle), so a plain file copy could catch a torn page. `.backup` is the
  # online-backup API and is safe against the live writer.
  systemd.services.wealthfolio-backup = {
    description = "Wealthfolio database backup";
    serviceConfig = { Type = "oneshot"; User = "wealthfolio"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/wealthfolio/wealthfolio.db ".backup '/mnt/data/backups/wealthfolio/wealthfolio-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/wealthfolio/wealthfolio-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/wealthfolio -name "wealthfolio-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.wealthfolio-backup = {
    description = "Daily Wealthfolio backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 04:15:00"; Persistent = true; };
  };

  # ── Karakeep (SQLite + assets) ─────────────────────────────────────────
  # Karakeep keeps everything under /var/lib/karakeep on the SSD — outside
  # /mnt/data, so restic (storj-backup.nix, which backs up /mnt/data only) never
  # saw it. Bookmarks, tags and AI summaries were unbacked from the day the
  # service landed; `nic.services.karakeep.backup` now pins this unit as the
  # answer, and lib/service-registration.nix asserts the unit exists.
  #
  # db.db holds the bookmarks; assets/ holds crawled favicons and images (the
  # local Chromium archiver is disabled, so this stays small). queue.db is the
  # job queue — regenerable, but 56 KB, so not worth the special case.
  # Runs as karakeep so it reads the 0600 DB whether or not the socket-idle
  # stack is awake; .backup only touches the file, not the running server.
  systemd.services.karakeep-backup = {
    description = "Karakeep database + assets backup";
    serviceConfig = { Type = "oneshot"; User = "karakeep"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      OUT=/mnt/data/backups/karakeep
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/karakeep/db.db ".backup '$OUT/karakeep-$STAMP.db'"
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/karakeep/queue.db ".backup '$OUT/karakeep-queue-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "$OUT/karakeep-$STAMP.db" "$OUT/karakeep-queue-$STAMP.db"
      # tar -z shells out to `gzip` from PATH, which the unit's minimal PATH lacks.
      ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
        -cf "$OUT/karakeep-assets-$STAMP.tar.gz" -C /var/lib/karakeep assets
      ${pkgs.findutils}/bin/find "$OUT" -type f -mtime +7 -delete
    '';
  };

  systemd.timers.karakeep-backup = {
    description = "Daily Karakeep backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 04:15:00"; Persistent = true; };
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
