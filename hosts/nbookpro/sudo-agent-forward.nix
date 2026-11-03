# Keeps the Bitwarden SSH agent reverse-forwarded to the Pi, where `mac-sudo`
# asks it for a signature (hosts/rpi5/security/sudo-ssh-agent.nix). The Pi admits it on
# tailnet identity (Tailscale SSH), so no key is offered and a reconnect never
# pops a Bitwarden prompt.
#
# One socket path per connection: tailscaled keeps a dead session's listener
# for hours (no server keepalive), and closing it unlinks its path, so a shared
# path got the live socket deleted from under it (2026-11-03).
{ config, pkgs, ... }:
let
  home = config.home.homeDirectory;
  logs = "${home}/Library/Logs/rpi5-sudo-agent.log";
  sshDir = "/home/nsimon/.ssh";
  tunnel = pkgs.writeShellApplication {
    name = "rpi5-sudo-agent";
    text = ''
      opts=(-o IdentityAgent=none -o ForwardAgent=no -o ConnectTimeout=15)
      sock=${sshDir}/sudo-agent.$(date +%s).sock
      /usr/bin/ssh "''${opts[@]}" nsimon@rpi5 \
        find ${sshDir} -maxdepth 1 -name "'sudo-agent*.sock'" -delete
      exec /usr/bin/ssh "''${opts[@]}" -N -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -R "$sock:${home}/.bitwarden-ssh-agent.sock" nsimon@rpi5
    '';
  };
in
{
  launchd.agents.rpi5-sudo-agent = {
    enable = true;
    config = {
      ProgramArguments = [ "${tunnel}/bin/rpi5-sudo-agent" ];
      KeepAlive = true;
      ThrottleInterval = 30; # retry pace while asleep or off the tailnet
      ProcessType = "Background";
      StandardOutPath = logs;
      StandardErrorPath = logs;
    };
  };
}
