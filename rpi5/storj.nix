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
      --transfers 2 \
      --checkers 4 \
      --create-empty-src-dirs \
      --max-size 25G \
      --exclude "lost+found/**"
  '';

  cleanupCli = pkgs.writeShellScriptBin "storj-cleanup" ''
    set -euo pipefail

    RCLONE="${pkgs.rclone}/bin/rclone"
    CONFIG="/run/agenix/rclone-storj"
    REMOTE="storj:rpi5-cloud"
    DRY_RUN=""

    _usage() {
      cat <<EOF
    Usage: storj-cleanup [--dry-run] <command> [args]

    Commands:
      usage                        Show bucket usage and quota
      ls [--top N]                 List top N largest files (default: 20)
      purge-older-than <days>      Delete files not modified in <days> days
      purge-larger-than <size>     Delete files larger than <size> (e.g. 100M, 1G)
    EOF
    }

    # Strip leading --dry-run flag
    if [[ "''${1:-}" == "--dry-run" ]]; then
      DRY_RUN="--dry-run"
      shift
    fi

    CMD="''${1:-}"
    shift || true

    case "$CMD" in
      usage)
        "$RCLONE" size "$REMOTE" --config "$CONFIG"
        ;;
      ls)
        TOP=20
        if [[ "''${1:-}" == "--top" && -n "''${2:-}" ]]; then
          TOP="$2"
        fi
        "$RCLONE" lsl "$REMOTE" --config "$CONFIG" \
          | sort -k1 -hr \
          | head -"$TOP"
        ;;
      purge-older-than)
        DAYS="''${1:?days argument required}"
        "$RCLONE" delete "$REMOTE" --config "$CONFIG" \
          --min-age "''${DAYS}d" \
          --rmdirs \
          ''${DRY_RUN}
        ;;
      purge-larger-than)
        SIZE="''${1:?size argument required (e.g. 100M, 1G)}"
        "$RCLONE" delete "$REMOTE" --config "$CONFIG" \
          --min-size "$SIZE" \
          --rmdirs \
          ''${DRY_RUN}
        ;;
      *)
        _usage
        exit 1
        ;;
    esac
  '';

  # Weekly sync to remove remote files that no longer exist locally.
  # Runs as a separate low-frequency job so a local accident has time to be
  # noticed before it propagates to Storj.
  weeklySyncScript = pkgs.writeShellScript "rclone-storj-weekly-sync" ''
    set -euo pipefail
    exec ${pkgs.rclone}/bin/rclone sync ${mountPoint} storj:rpi5-cloud \
      --config /run/agenix/rclone-storj \
      --transfers 2 \
      --checkers 4 \
      --delete-after \
      --max-size 25G \
      --exclude "lost+found/**"
  '';
in
{
  environment.systemPackages = [ pkgs.rclone cleanupCli ];

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

  # Weekly reconciliation — deletes remote files removed locally.
  systemd.services.rclone-storj-weekly-sync = {
    description = "Sync /mnt/cloud to Storj (delete orphaned remote files)";
    after        = [ "network-online.target" "storj-local-mount.service" ];
    wants        = [ "network-online.target" ];
    requires     = [ "storj-local-mount.service" ];

    serviceConfig = {
      Type      = "oneshot";
      ExecStart = weeklySyncScript;
    };
  };

  systemd.timers.rclone-storj-weekly-sync = {
    description = "Sync /mnt/cloud to Storj every Wednesday at 03:00";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Wed *-*-* 03:00:00";
      Persistent = true;
    };
  };
}
