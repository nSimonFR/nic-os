{ pkgs, ... }:
let
  sessionName = "claude-rc";

  # The Nix wrapper prepends `--mcp-config <configs...>` which swallows
  # the `remote-control` subcommand (parsed as a second config path).
  # Work around: resolve the unwrapped binary at runtime and call it
  # directly with the subcommand.
  startScript = pkgs.writeShellScript "claude-remote-control-start" ''
    CLAUDE_BIN="/etc/profiles/per-user/nsimon/bin/claude"

    # Extract the real binary from the Nix wrapper
    REAL_BIN=$(${pkgs.gnused}/bin/sed -n 's/^exec -a "\$0" "\(.*\)"\s\+--mcp-config .*/\1/p' "$CLAUDE_BIN")

    if [ -z "$REAL_BIN" ] || [ ! -x "$REAL_BIN" ]; then
      echo "Failed to resolve claude binary from wrapper" >&2
      exit 1
    fi

    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
    ${pkgs.tmux}/bin/tmux new-session -d -s ${sessionName} \
      "$REAL_BIN remote-control \
        --spawn worktree \
        --capacity 8 \
        --permission-mode bypassPermissions"
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
      User = "nsimon";
      Group = "users";
      WorkingDirectory = "/home/nsimon/nic-os";
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
