# Keeps the Bitwarden SSH agent reverse-forwarded to the Pi, where `mac-sudo`
# asks it for a signature (hosts/rpi5/sudo-ssh-agent.nix). The Pi admits it on
# tailnet identity (Tailscale SSH), so no key is offered and a reconnect never
# pops a Bitwarden prompt. sshd's StreamLocalBindUnlink doesn't apply to
# tailscaled, so the tunnel clears a stale socket itself.
{ config, pkgs, ... }:
let
  home = config.home.homeDirectory;
  logs = "${home}/Library/Logs/rpi5-sudo-agent.log";
  sock = "/home/nsimon/.ssh/sudo-agent.sock";
  tunnel = pkgs.writeShellApplication {
    name = "rpi5-sudo-agent";
    text = ''
      opts=(-o IdentityAgent=none -o ForwardAgent=no -o ConnectTimeout=15)
      /usr/bin/ssh "''${opts[@]}" nsimon@rpi5 rm -f ${sock}
      exec /usr/bin/ssh "''${opts[@]}" -N -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -R ${sock}:${home}/.bitwarden-ssh-agent.sock nsimon@rpi5
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
