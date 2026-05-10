{ unstablePkgs, ... }:
{
  # Keep atuin's sync daemon alive headlessly so background hooks (e.g. the
  # Claude Code Bash PostToolUse hook) and history written outside an
  # interactive shell session still sync to api.atuin.sh. The shell init
  # `atuin init zsh` only spawns a daemon when zsh starts, so on a
  # mostly-headless box the socket dies and sync silently lapses.
  systemd.user.services.atuin-daemon = {
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
      ExecStart = "${unstablePkgs.atuin}/bin/atuin daemon start";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
