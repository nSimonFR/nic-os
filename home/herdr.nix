# herdr's headless server on the Linux hosts, so remote sessions outlive the
# thing that opened them.
#
# The split matters for how this is used: `herdr --remote rpi5` (or a saved
# machine, `herdr machine add`) runs the CLIENT on the Mac and reaches the
# SERVER over plain OpenSSH — the panes, PTYs and agent processes all live on
# the remote. Closing the laptop therefore drops only the client; the work keeps
# running. But that only holds while a server is up, and started by hand it dies
# with the first reboot, which is what this unit fixes.
#
# Linux only. The Mac runs `herdr` interactively and starts its own server on
# demand, so a launchd agent would only race it.
{
  pkgs,
  lib,
  unstablePkgs,
  ...
}:

{
  systemd.user.services.herdr = lib.mkIf pkgs.stdenv.isLinux {
    Unit = {
      Description = "herdr headless server";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Install.WantedBy = [ "default.target" ];
    Service = {
      Type = "simple";
      # `herdr server` is the headless form; bare `herdr` would try to open a
      # TUI and exit for want of a terminal.
      ExecStart = "${unstablePkgs.herdr}/bin/herdr server";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
