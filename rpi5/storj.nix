{ config, pkgs, ... }:
let
  localImg   = "/home/state/cloud.img";
  mountPoint = "/mnt/cloud";

  mountScript = pkgs.writeShellScript "storj-local-mount" ''
    mkdir -p /home/state
    if [ ! -f ${localImg} ]; then
      dd if=/dev/zero of=${localImg} bs=1 count=0 seek=25G
      ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F ${localImg}
    fi
    mkdir -p ${mountPoint}
    ${pkgs.util-linux}/bin/mount -o loop,noatime ${localImg} ${mountPoint}
  '';
in
{
  environment.systemPackages = [ pkgs.rclone ];

  # 25G sparse ext4 image on NVMe RAID, loop-mounted at /mnt/cloud
  systemd.services.storj-local-mount = {
    description = "Loop-mount 25G local image at /mnt/cloud";
    after        = [ "home.mount" ];
    requires     = [ "home.mount" ];
    before       = [ "rclone-storj-sync.service" ];
    wantedBy     = [ "multi-user.target" ];

    serviceConfig = {
      Type              = "oneshot";
      RemainAfterExit   = true;
      ExecStart         = mountScript;
      ExecStop          = "${pkgs.util-linux}/bin/umount ${mountPoint}";
    };
  };

  # Async sync to Storj — runs every 5 minutes, writes never block on Storj
  systemd.services.rclone-storj-sync = {
    description = "Sync /mnt/cloud to Storj (25G cap)";
    after        = [ "network-online.target" "storj-local-mount.service" ];
    wants        = [ "network-online.target" ];
    requires     = [ "storj-local-mount.service" ];

    serviceConfig = {
      Type      = "oneshot";
      ExecStart = "${pkgs.rclone}/bin/rclone sync ${mountPoint} storj: --config /run/agenix/rclone-storj --transfers 4 --create-empty-src-dirs --max-size 25G";
    };
  };

  systemd.timers.rclone-storj-sync = {
    description = "Trigger Storj sync every 5 minutes";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnBootSec        = "5min";
      OnUnitActiveSec  = "5min";
    };
  };
}
