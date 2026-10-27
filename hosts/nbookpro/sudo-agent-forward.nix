# Keeps the Bitwarden SSH agent reverse-forwarded to the Pi, where `mac-sudo`
# asks it for a signature (hosts/rpi5/sudo-ssh-agent.nix). The tunnel logs in
# with its own on-disk key so a reconnect never pops a Bitwarden prompt; it is
# authorized on the Pi for forwarding only.
#   ssh-keygen -t ed25519 -N "" -C nbookpro-sudo-tunnel -f ~/.ssh/rpi5_sudo_tunnel
{ config, ... }:
let
  home = config.home.homeDirectory;
  logs = "${home}/Library/Logs/rpi5-sudo-agent.log";
in
{
  launchd.agents.rpi5-sudo-agent = {
    enable = true;
    config = {
      ProgramArguments = [
        "/usr/bin/ssh" "-N"
        "-i" "${home}/.ssh/rpi5_sudo_tunnel"
        "-o" "IdentitiesOnly=yes" "-o" "IdentityAgent=none" "-o" "ForwardAgent=no"
        "-o" "ExitOnForwardFailure=yes"
        "-o" "ServerAliveInterval=30" "-o" "ServerAliveCountMax=3"
        "-R" "/home/nsimon/.ssh/sudo-agent.sock:${home}/.bitwarden-ssh-agent.sock"
        "nsimon@rpi5"
      ];
      KeepAlive = true;
      ThrottleInterval = 30; # retry pace while asleep or off the tailnet
      ProcessType = "Background";
      StandardOutPath = logs;
      StandardErrorPath = logs;
    };
  };
}
