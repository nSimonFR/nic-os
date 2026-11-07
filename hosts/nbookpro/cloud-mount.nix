# rpi5's /mnt/data/cloud (Nextcloud's files) as ~/Cloud on the Mac.
#
# Replaces the Tailscale Drive mount, which went with the Tailscale app: tailmux
# has no Drive client. rclone's `nfsmount` serves the sftp backend through the
# macOS NFS client, so there is no FUSE layer and no sudo.
#
# Reaches rpi5 over Tailscale SSH with the agent off, like sudo-agent-forward.nix,
# so a reconnect never waits on a Bitwarden unlock.
#
# Measured over the tailnet (36 ms RTT): first listing of 1.1k files 14 s, a cold
# file ~0.4 s, a 128 MB file ~13 s; warm, 0.2 s / 0.003 s / 0.13 s. Changes made
# elsewhere show up once the 10 min metadata cache expires.
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
        --vfs-cache-mode full \
        --vfs-cache-max-age 24h \
        --vfs-cache-max-size 5G \
        --vfs-read-ahead 16M \
        --dir-cache-time 10m \
        --attr-timeout 10m \
        --sftp-concurrency 16 \
        --sftp-set-modtime=false
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
