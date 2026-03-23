{ config, pkgs, username, ... }:
let
  localImg    = "/home/state/cloud.img";
  mountPoint  = "/mnt/cloud";
  # Sentinel written when a fresh image is created. Presence means the sync
  # service must check Storj before uploading to avoid treating an empty local
  # mount as truth and wiping existing remote data.
  freshMarker = "/home/state/cloud.img.fresh";

  mountScript = pkgs.writeShellScript "storj-local-mount" ''
    mkdir -p /home/state
    if [ ! -f ${localImg} ]; then
      dd if=/dev/zero of=${localImg} bs=1 count=0 seek=25G
      ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F ${localImg}
      touch ${freshMarker}
    fi
    mkdir -p ${mountPoint}
    ${pkgs.util-linux}/bin/mount -o loop,noatime ${localImg} ${mountPoint}
    # Make the mount root writable by the primary user (root owns the ext4
    # root dir after a fresh mkfs; adjust after every mount in case the image
    # was created on a different host).
    chown ${username} ${mountPoint}
    chmod 755 ${mountPoint}
  '';

  syncScript = pkgs.writeShellScript "rclone-storj-sync" ''
    set -euo pipefail

    if [ -f ${freshMarker} ]; then
      # Fresh image: check whether Storj already has data before uploading.
      # If Storj is non-empty this is a recovery case — restore from remote
      # instead of overwriting it with an empty local mount.
      # If Storj is empty this is a genuine first boot — remove the marker
      # and let the next timer run push local data normally.
      remote_count=$(${pkgs.rclone}/bin/rclone lsf storj:rpi5-cloud \
        --config /run/agenix/rclone-storj 2>/dev/null | wc -l)

      if [ "$remote_count" -gt 0 ]; then
        echo "Fresh local image but Storj has data — restoring from storj:rpi5-cloud"
        ${pkgs.rclone}/bin/rclone copy storj:rpi5-cloud ${mountPoint} \
          --config /run/agenix/rclone-storj \
          --transfers 4
      else
        echo "Fresh local image and Storj is empty — first boot, skipping upload"
      fi
      rm ${freshMarker}
      exit 0
    fi

    exec ${pkgs.rclone}/bin/rclone copy ${mountPoint} storj:rpi5-cloud \
      --config /run/agenix/rclone-storj \
      --transfers 4 \
      --create-empty-src-dirs \
      --max-size 25G \
      --exclude "lost+found/**"
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
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = mountScript;
      ExecStop        = "${pkgs.util-linux}/bin/umount ${mountPoint}";
    };
  };

  # Async copy to Storj — runs every 5 minutes, writes never block on Storj.
  # Uses rclone copy (not sync) so local data loss never deletes remote files.
  systemd.services.rclone-storj-sync = {
    description = "Copy /mnt/cloud to Storj (25G cap)";
    after        = [ "network-online.target" "storj-local-mount.service" ];
    wants        = [ "network-online.target" ];
    requires     = [ "storj-local-mount.service" ];

    serviceConfig = {
      Type      = "oneshot";
      ExecStart = syncScript;
    };
  };

  systemd.timers.rclone-storj-sync = {
    description = "Copy /mnt/cloud to Storj every 5 minutes";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "5min";
      OnUnitActiveSec = "5min";
    };
  };
}
