# storj-backup.nix — the off-site half: restic pushes /mnt/data to Storj.
#
# Everything that reaches Storj reaches it through this one unit, because
# /mnt/data is the only path it backs up. A service's state gets there either by
# living on the HDD already (`backup = [ "mnt-data" ]`) or by a nightly dump unit
# writing under /mnt/data/backups (`postgres` / `unit`) — see
# lib/service-registration.nix.
#
# ── Ordering ────────────────────────────────────────────────────────────────
# Which means restic must not run *while* those dumps are being written. It used
# to: the timer was 03:00 with `RandomizedDelaySec = 1h`, so it started somewhere
# in 03:00–04:00, and the dumps ran 03:00 (postgres), 03:15 (vaultwarden,
# forgejo), 03:45 (papra, gramps-web, wakapi), 04:00 (beaverhabits), 04:15
# (karakeep). Two consequences, both silent:
#
#   * restic could read a `.gz` mid-`gzip` and upload a truncated dump;
#   * karakeep and beaverhabits, whose timers usually fired after restic had
#     finished, were shipped a day stale every single night.
#
# So the timer now sits at 04:30 — after the last dump — and the unit is ordered
# `After=` every dump unit as a backstop for the pathological case (a large
# `pg_dump` still running at 04:30 holds restic until it finishes; ordering
# applies to queued jobs, so an already-completed dump costs nothing).
#
# `After=` only, deliberately not `Wants=`: a dump that fails must not stop the
# upload of the twenty that succeeded. A failed dump leaves restic uploading
# yesterday's file; `backup-freshness` below is what notices — including a unit
# that exits 0 having written nothing, which is how Immich's `pg_dump` went 34
# days unseen.
{
  config,
  lib,
  pkgs,
  telegramChatId,
  ...
}:
let
  restic = config.services.restic.backups.storj-daily;
  remote = lib.removePrefix "rclone:" restic.repository;

  telegramAlert = (import ../../../shared/notify.nix { inherit pkgs; }).alert {
    tokenFile = config.age.secrets.telegram-bot-token.path;
    chatId = telegramChatId;
    name = "telegram-alert-storj";
  };

  # Same repo/credentials/cache as the backup unit, minus PATH and unset vars.
  resticEnv = lib.filterAttrs (
    n: v: v != null && n != "PATH"
  ) config.systemd.services.restic-backups-storj-daily.environment;

  resticLimits = {
    Nice = 10;
    IOSchedulingClass = "idle";
    CPUQuota = "50%";
  };

  backupFreshness = pkgs.writeShellApplication {
    name = "backup-freshness";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      jq
      rclone
    ];
    text = builtins.readFile ../scripts/backup-freshness.sh;
  };

  # Every unit that writes a dump under /mnt/data/backups, derived rather than
  # listed: the postgres ones from the databases each service registered, the
  # rest from `nic.services.*.backupUnits`. A new service with a dump unit is
  # ordered ahead of restic by registering, with nothing to remember here.
  dumpUnits =
    config.nic.backupUnits
    ++ map (db: "postgresqlBackup-${db}.service") config.services.postgresqlBackup.databases;
in
{
  services.restic.backups.storj-daily = {
    # rclone:<remote-name>:<bucket> — uses the existing "storj" remote
    repository = "rclone:storj:rpi5-mnt-data";
    passwordFile = "/run/agenix/restic-password";
    rcloneConfigFile = "/run/agenix/rclone-storj";

    # The repo exists. With this on, a refused download also ran `restic init`,
    # whose "config file already exists" buried the real error.
    initialize = false;

    paths = [ "/mnt/data" ];
    exclude = [
      "lost+found"
      "/mnt/data/nix-build" # nix's build-dir (configuration.nix): transient
      "/mnt/data/swapfile"
      # Scryfall catalogue + a Moxfield mirror, both re-fetchable; ~0.9 GB
      # rewritten nightly (showmycards.nix).
      "/mnt/data/showmycards"
    ];

    timerConfig = {
      # 04:30 local (Europe/Paris) — 15 min after karakeep, the last dump, and
      # comfortably before the Sunday 05:00 reboot (auto-reboot.nix).
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true; # catch up if the RPi was off at 04:30
      # Jitter kept small for the same reason it shrank: the window between the
      # last dump and the reboot is 30 minutes wide, and there is no
      # thundering herd to spread out on a single host.
      RandomizedDelaySec = "10m";
    };

    # The project caps downloads at 10 GB/month, and repacking downloads every
    # pack it rewrites: at the default 5% this re-downloaded ~300 MB a night and
    # exhausted the cap on 2026-11-11. `unlimited` only deletes packs that are
    # wholly unused, so pruning downloads nothing; the leftover garbage costs
    # cents of storage.
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
      "--max-unused unlimited"
    ];

    extraBackupArgs = [
      "--one-file-system" # don't cross bind mounts (e.g. SSD-backed immich dirs)
      "--pack-size 60" # 60 MiB packs — reduces Storj segment fees
      "--exclude-caches"
    ];
  };

  systemd.services.restic-backups-storj-daily = {
    after = dumpUnits;

    # Resource limits: RPi5 has 4 GiB RAM; prevent restic from competing
    # with HA, Immich, etc.
    serviceConfig = resticLimits;
  };

  # ── Verification ────────────────────────────────────────────────────────────
  # Both fail loudly; systemd-failed-alert (monitoring.nix) relays to Telegram.
  systemd.services.backup-freshness = {
    description = "Check every dump and the Storj snapshot are fresh";
    after = [ "restic-backups-storj-daily.service" ];
    environment = resticEnv // {
      STORJ_REMOTE = remote;
      STORJ_ALERT = telegramAlert;
      PG_DIR = config.services.postgresqlBackup.location;
      PG_DBS = toString config.services.postgresqlBackup.databases;
      DUMP_ROOT = "/mnt/data/backups";
      MAX_AGE_H = "26";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe backupFreshness;
    };
  };

  systemd.timers.backup-freshness = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 07:00:00";
      Persistent = true;
    };
  };

  # Reads back ~1 GiB of random packs a month. The weekly 5% (4.6 GB) was half
  # the 10 GB download cap; Storj already checks its own erasure-coded data.
  systemd.services.restic-check-storj = {
    description = "restic integrity check of the Storj repository";
    environment = resticEnv;
    serviceConfig = resticLimits // {
      Type = "oneshot";
      ExecStart = "${lib.getExe restic.package} check --read-data-subset=1G";
    };
  };

  systemd.timers.restic-check-storj = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 11:00:00";
      Persistent = true;
    };
  };
}
