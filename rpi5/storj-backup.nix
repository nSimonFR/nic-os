{ config, pkgs, ... }:
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
      OnCalendar = "*-*-* 03:00:00"; # 3 AM local (Europe/Paris)
      Persistent = true;              # catch up if the RPi was off at 3 AM
      RandomizedDelaySec = "1h";
    };

    pruneOpts = [
      "--keep-daily 7"
      "--keep-monthly 6"
    ];

    extraBackupArgs = [
      "--pack-size 60"     # 60 MiB packs — reduces Storj segment fees
      "--exclude-caches"
    ];
  };

  # Resource limits: RPi5 has 4 GiB RAM; prevent restic from competing
  # with HA, Immich, etc.
  systemd.services.restic-backups-storj-daily.serviceConfig = {
    Nice = 10;
    IOSchedulingClass = "idle";
    MemoryMax = "512M";
    CPUQuota = "50%";
  };
}
