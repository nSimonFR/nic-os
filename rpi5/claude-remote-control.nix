{ pkgs, ... }:
let
  claudeBin = "/etc/profiles/per-user/nsimon/bin/claude";
  sessionName = "claude-rc";

  # Claude Code --remote-control requires a TTY (interactive session).
  # We use tmux to provide a virtual terminal that systemd can manage.
  startScript = pkgs.writeShellScript "claude-remote-control-start" ''
    # Kill any stale session
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
    # Start claude with remote-control in a detached tmux session
    exec ${pkgs.tmux}/bin/tmux new-session -d -s ${sessionName} \
      "${claudeBin} --dangerously-skip-permissions --remote-control"
  '';
in
{
  systemd.services.claude-remote-control = {
    description = "Claude Code Remote Control server (tmux)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "forking";
      User = "nsimon";
      Group = "users";
      WorkingDirectory = "/home/nsimon";
      ExecStart = startScript;
      ExecStop = "${pkgs.tmux}/bin/tmux kill-session -t ${sessionName}";
      Restart = "on-failure";
      RestartSec = "30s";
      Environment = [
        "HOME=/home/nsimon"
        "PATH=/etc/profiles/per-user/nsimon/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
  };
}
