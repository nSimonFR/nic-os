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
    "d /mnt/data/backups/blogwatcher 0750 nsimon users -"
    "d /mnt/data/backups/hermes 0750 nsimon users -"
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

  # ── Registration for the two $HOME dumps below ─────────────────────────
  # Both of these live here rather than in an owning module, which is unusual
  # enough to say why: blogwatcher is a bare CLI with no module at all, and
  # Hermes' module (hosts/rpi5/hermes/hermes.nix) is a *home-manager* module,
  # where `nic.services` — a NixOS option — does not exist.
  #
  # Registering is not paperwork. `nic.backupUnits` is what storj-backup.nix
  # orders restic `After=`, and restic's timer carries `RandomizedDelaySec =
  # 10m`, so it starts anywhere in 04:30–04:40. Without an entry here the only
  # thing keeping a dump out of a half-written upload is the gap between two
  # wall-clock times — which is exactly the arrangement the ordering was added
  # to replace.
  nic.services.blogwatcher = {
    backup = [ "unit" ];
    backupUnits = [ "blogwatcher-backup.service" ];
  };

  nic.services.hermes = {
    backup = [ "unit" ];
    backupUnits = [ "hermes-backup.service" ];
  };

  # ── blogwatcher (SQLite in $HOME) ──────────────────────────────────────
  # The tracked feeds and the read/unread state of every article live in
  # /home/nsimon/.blogwatcher/blogwatcher.db, on the SSD, outside /mnt/data,
  # and restic (storj-backup.nix) backs up /mnt/data and nothing else. The
  # daily digest (hermes/workspace/daily-pending-digest.sh) calls `read-all`
  # every morning, so the unread set is *only* here — nothing upstream can
  # rebuild it.
  #
  # 0.0.3 made this urgent rather than theoretical: it migrates the schema in
  # place on first open (ALTER TABLE blogs ADD COLUMN user_agent), so the very
  # first blogwatcher command after the upgrade rewrites the only copy.
  #
  # Runs as nsimon because the DB is in that home; `.backup` is the online
  # backup API, safe against a `scan` running concurrently.
  systemd.services.blogwatcher-backup = {
    description = "blogwatcher database backup";
    serviceConfig = { Type = "oneshot"; User = "nsimon"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /home/nsimon/.blogwatcher/blogwatcher.db ".backup '/mnt/data/backups/blogwatcher/blogwatcher-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/blogwatcher/blogwatcher-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/blogwatcher -name "blogwatcher-*.db.gz" -mtime +7 -delete
    '';
  };

  # 04:20, ahead of restic's 04:30–04:40 window, so the dump is a day old at
  # most rather than a day stale. The `After=` ordering above is the guarantee;
  # this is the margin that keeps it from ever mattering.
  systemd.timers.blogwatcher-backup = {
    description = "Daily blogwatcher backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 04:20:00"; Persistent = true; };
  };

  # ── Hermes (SQLite + runtime files in $HOME) ───────────────────────────
  # Hermes is the sole agent, and everything it has ever said or been told is
  # in /home/nsimon/.hermes — on the SSD, outside /mnt/data, so restic never
  # saw any of it. state.db alone is 91 MB: 7,301 messages across 141 sessions
  # plus their FTS index. None of it is reconstructible from anywhere.
  #
  # What is dumped, and what is deliberately not:
  #
  #   state.db                 conversation history + sessions (the big one)
  #   kanban.db                the agent's task board
  #   memory_store.db          what it has chosen to remember
  #   verification_evidence.db  its own verification trail
  #   cron/executions.db       job run history
  #   memories/, memory/       MEMORY.md / USER.md, written at runtime
  #   cron/jobs.json           live job definitions — editable by the agent,
  #                            so the repo is NOT a copy of this
  #
  # Skipped because a rebuild recreates them: skills/ (58 MB, rsynced from the
  # store), documents (likewise), lsp/, cache/, audio_cache/, image_cache/,
  # logs/, and sessions/ (3.6 MB of request_dump_*.json debug artefacts — the
  # conversations themselves are in state.db). .env is agenix-derived. That is
  # 211 MB on disk reduced to ~40 MB dumped.
  #
  # `.timeout 60000` before `.backup`, which the other units here do without:
  # they dump databases that are idle at 04:00, whereas Hermes writes
  # continuously and would otherwise lose the race to a busy database.
  systemd.services.hermes-backup = {
    description = "Hermes agent state backup";
    serviceConfig = { Type = "oneshot"; User = "nsimon"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      OUT=/mnt/data/backups/hermes
      H=/home/nsimon/.hermes
      for db in state kanban memory_store verification_evidence; do
        ${pkgs.sqlite}/bin/sqlite3 "$H/$db.db" ".timeout 60000" ".backup '$OUT/$db-$STAMP.db'"
      done
      ${pkgs.sqlite}/bin/sqlite3 "$H/cron/executions.db" ".timeout 60000" ".backup '$OUT/executions-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "$OUT"/*-"$STAMP".db
      # tar -z shells out to `gzip` from PATH, which the unit's minimal PATH lacks.
      ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
        -cf "$OUT/files-$STAMP.tar.gz" -C "$H" memories memory cron/jobs.json
      ${pkgs.findutils}/bin/find "$OUT" -type f -mtime +7 -delete
    '';
  };

  systemd.timers.hermes-backup = {
    description = "Daily Hermes backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 04:25:00"; Persistent = true; };
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
