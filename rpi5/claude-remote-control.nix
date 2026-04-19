{ pkgs, username, ... }:
let
  sessionName = "claude-rc";
  claudeRc = "/home/${username}/.claude/bin/claude-rc";

  startScript = pkgs.writeShellScript "claude-remote-control-start" ''
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
    ${pkgs.tmux}/bin/tmux new-session -d -s ${sessionName} \
      "${claudeRc} \
        --spawn worktree \
        --capacity 8 \
        --permission-mode bypassPermissions"
  '';

  # Watchdog: restart the tmux session if claude died inside it.
  # systemd only tracks the tmux launcher (Type=oneshot), not the
  # claude process inside the pane — this timer catches silent failures.
  watchdogScript = pkgs.writeShellScript "claude-remote-control-watchdog" ''
    # tmux sessions are per-user; check as the service user via su
    if ! su -l ${username} -c '${pkgs.tmux}/bin/tmux has-session -t ${sessionName} 2>/dev/null'; then
      echo "tmux session ${sessionName} missing, restarting service"
      systemctl restart claude-remote-control.service
    fi
  '';
in
{
  systemd.services.claude-remote-control = {
    description = "Claude Code Remote Control server (tmux)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = username;
      Group = "users";
      WorkingDirectory = "/home/${username}/nic-os";
      ExecStart = startScript;
      ExecStop = "${pkgs.tmux}/bin/tmux kill-session -t ${sessionName}";
      Environment = [
        "HOME=/home/${username}"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
  };

  # Timer-based watchdog: check every 5 minutes, restart if tmux session died
  systemd.services.claude-remote-control-watchdog = {
    description = "Claude Code Remote Control watchdog";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = watchdogScript;
    };
  };

  systemd.timers.claude-remote-control-watchdog = {
    description = "Claude Code Remote Control watchdog timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };
}
