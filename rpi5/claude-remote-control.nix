{ pkgs, username, ... }:
let
  sessionName = "claude-rc";
  claudeRc = "/home/${username}/.claude/bin/claude-rc";

  stopScript = pkgs.writeShellScript "claude-remote-control-stop" ''
    # Send SIGTERM to the claude process inside tmux, giving it time
    # to deregister from Anthropic's API before we kill the session.
    ${pkgs.tmux}/bin/tmux send-keys -t ${sessionName} C-c 2>/dev/null || true
    sleep 3
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
  '';

  startScript = pkgs.writeShellScript "claude-remote-control-start" ''
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
    ${pkgs.tmux}/bin/tmux new-session -d -s ${sessionName} \
      "${claudeRc} \
        --spawn worktree \
        --no-create-session-in-dir \
        --capacity 8 \
        --permission-mode bypassPermissions \
        --name rpi5 \
        --verbose \
        --debug-file /tmp/claude-rc-debug.log"
  '';

  watchdogScript = pkgs.writeShellScript "claude-remote-control-watchdog" ''
    # tmux server is per-user; point to the user's socket
    TMUX_SOCKET="/tmp/tmux-$(id -u ${username})/default"
    if ! ${pkgs.tmux}/bin/tmux -S "$TMUX_SOCKET" has-session -t ${sessionName} 2>/dev/null; then
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
    # Stop cleanly before rebuilds: nixos-rebuild triggers stop→start
    stopIfChanged = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = username;
      Group = "users";
      WorkingDirectory = "/home/${username}/nic-os";
      ExecStart = startScript;
      ExecStop = stopScript;
      TimeoutStopSec = "10s";
      Environment = [
        "HOME=/home/${username}"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
  };

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
