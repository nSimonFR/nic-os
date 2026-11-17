{
  pkgs,
  lib,
  config,
  ...
}:
let
  # Daily removal of git worktrees nobody uses: untouched for 7 days, clean, and with
  # every commit on a remote. See scripts/worktree-gc.sh for the exact rules.
  worktreeGc = pkgs.writeShellApplication {
    name = "worktree-gc";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
      pkgs.gawk
    ];
    text = builtins.readFile ./scripts/worktree-gc.sh;
  };
  logFile = "${config.xdg.stateHome}/worktree-gc.log";
in
{
  # On PATH too, for `worktree-gc --dry-run`.
  home.packages = [ worktreeGc ];

  launchd.agents.worktree-gc = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe worktreeGc) ];
      # launchd runs a calendar job missed during sleep at the next wake.
      StartCalendarInterval = [
        {
          Hour = 13;
          Minute = 0;
        }
      ];
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
      LowPriorityIO = true;
      Nice = 10;
    };
  };

  systemd.user.services.worktree-gc = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Remove unused git worktrees";
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe worktreeGc;
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };
  systemd.user.timers.worktree-gc = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Daily removal of unused git worktrees";
    Timer = {
      OnCalendar = "13:00";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
