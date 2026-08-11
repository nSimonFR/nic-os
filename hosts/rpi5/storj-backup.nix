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
# upload of the twenty that succeeded. The cost of that choice is that a failed
# dump leaves restic uploading yesterday's file, and nothing here notices —
# `systemd-failed-alert` (monitoring.nix) catches a unit that *fails*, not one
# that exits 0 having written nothing, which is how Immich's `pg_dump` went 34
# days unseen.
{ config, ... }:
let
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

    initialize = true; # auto-run `restic init` on first backup

    paths = [ "/mnt/data" ];
    exclude = [
      "lost+found"
    ];

    timerConfig = {
      # 04:30 local (Europe/Paris) — 15 min after karakeep, the last dump, and
      # comfortably before the Sunday 05:00 auto-upgrade (auto-upgrade.nix).
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true; # catch up if the RPi was off at 04:30
      # Jitter kept small for the same reason it shrank: the window between the
      # last dump and the auto-upgrade is 30 minutes wide, and there is no
      # thundering herd to spread out on a single host.
      RandomizedDelaySec = "10m";
    };

    pruneOpts = [
      "--keep-daily 7"
      "--keep-monthly 6"
    ];

    extraBackupArgs = [
      "--one-file-system"  # don't cross bind mounts (e.g. SSD-backed immich dirs)
      "--pack-size 60"     # 60 MiB packs — reduces Storj segment fees
      "--exclude-caches"
    ];
  };

  systemd.services.restic-backups-storj-daily = {
    after = dumpUnits;

    # Resource limits: RPi5 has 4 GiB RAM; prevent restic from competing
    # with HA, Immich, etc.
    serviceConfig = {
      Nice = 10;
      IOSchedulingClass = "idle";
      MemoryMax = "512M";
      CPUQuota = "50%";
    };
  };
}
