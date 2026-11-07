# rpi5's /mnt/data/cloud (Nextcloud's files) as ~/Cloud on the Mac.
#
# Replaces the Tailscale Drive mount, which went with the Tailscale app: tailmux
# has no Drive client. rclone's `nfsmount` serves the sftp backend through the
# macOS NFS client, so there is no FUSE layer and no sudo.
#
# Reaches rpi5 over Tailscale SSH with the agent off, like sudo-agent-forward.nix,
# so a reconnect never waits on a Bitwarden unlock.
#
# Writes land on disk, not in Nextcloud: only NOTES is rescanned (open-knowledge.nix),
# so a file added elsewhere shows in the web UI after the next `occ files:scan`.
{ config, pkgs, ... }:
let
  home = config.home.homeDirectory;
  mountPoint = "${home}/Cloud";
  logs = "${home}/Library/Logs/cloud-mount.log";
  sshCmd = "/usr/bin/ssh -o IdentityAgent=none -o ForwardAgent=no -o BatchMode=yes -o ConnectTimeout=15 nsimon@rpi5";
  mount = pkgs.writeShellApplication {
    name = "cloud-mount";
    runtimeInputs = [ pkgs.rclone ];
    text = ''
      mkdir -p "${mountPoint}"
      # A killed rclone leaves a dead NFS mount behind; touching it would hang.
      /usr/sbin/diskutil unmount force "${mountPoint}" >/dev/null 2>&1 || true
      exec rclone nfsmount :sftp:/mnt/data/cloud "${mountPoint}" \
        --sftp-ssh "${sshCmd}" \
        --volname cloud \
        --vfs-cache-mode writes \
        --dir-cache-time 30s
    '';
  };
in
{
  launchd.agents.cloud-mount = {
    enable = true;
    config = {
      ProgramArguments = [ "${mount}/bin/cloud-mount" ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30; # retry pace while asleep or off the tailnet
      ProcessType = "Background";
      StandardOutPath = logs;
      StandardErrorPath = logs;
    };
  };
}
