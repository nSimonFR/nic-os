{
  lib,
  pkgs,
  config,
  unstablePkgs,
  ...
}:
let
  # Keep this in lockstep with the atuin CLI on PATH (home/packages.nix uses
  # unstablePkgs.atuin). If the daemon and the client diverge, the client talks
  # to a stale daemon binary over the socket and sync silently lapses.
  atuinBin = "${unstablePkgs.atuin}/bin/atuin";
in
{
  # Keep atuin's sync daemon (`daemon.enabled = true` in dotfiles/atuin.toml)
  # alive headlessly so background hooks (e.g. the Claude Code Bash PostToolUse
  # hook in home/scripts/claude-bash-history.sh) and history written outside an
  # interactive shell still sync to api.atuin.sh. `atuin init zsh` does NOT
  # start the daemon on its own, so without a real process supervisor the daemon
  # dies — or, worse, lingers on a stale binary after an atuin version bump —
  # and sync quietly stops. Each platform gets its native supervisor; the
  # supervisor restarts the daemon on the new binary whenever atuinBin changes,
  # which closes the version-skew gap.
  #
  # 2026-06-15: the macOS box had been running an orphaned 18.15.2 daemon since
  # April because only the Linux (systemd) path existed — darwin had no
  # equivalent and home-manager silently ignored the systemd block here. Hence
  # the launchd agent below.

  systemd.user.services = lib.mkIf pkgs.stdenv.isLinux {
    atuin-daemon = {
      Unit = {
        Description = "Atuin sync daemon";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${atuinBin} daemon start";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };

  launchd.agents.atuin-daemon = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    config = {
      ProgramArguments = [
        atuinBin
        "daemon"
        "start"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/.local/share/atuin/daemon.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.local/share/atuin/daemon.err.log";
    };
  };
}
