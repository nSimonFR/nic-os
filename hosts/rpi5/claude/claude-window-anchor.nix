# Start acct1's 5h usage window at 07:00 / 12:00 / 17:00, so a 08:30–12:00 +
# 13:30–20:00 day splits ~3.5h / 3.5h / 3h across three budgets. If a window is
# still open at an anchor, the run sleeps until it resets and pings then.
#
# Separate from claude-token-refresh on purpose: that one pings asale-luna, so
# it never touches the Anthropic account.
#
# On-demand: sudo systemctl start claude-window-anchor
# Logic: hosts/rpi5/scripts/lib/nicos_scripts/claude/window_anchor.py
{ pkgs, username, ... }:
{
  systemd.services.claude-window-anchor = {
    description = "Anchor the Claude 5h usage window to fixed times of day";
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      ExecStart = "${pkgs.nicos-scripts}/bin/claude-window-anchor";
      # Sleeps until an open window resets: under 5h by construction.
      TimeoutStartSec = "5h 15min";
      Environment = [
        "HOME=/home/${username}"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        # Same store as claude-token-refresh, so a ping that refreshes the token
        # rotates the owning credentials.json.
        "CLAUDE_CONFIG_DIR=/home/${username}/.claude-rc"
        "ANCHOR_DAY_START=07:00"
        "ANCHOR_DAY_END=20:00"
        "ANCHOR_DRY_RUN=0"
      ];
    };
  };

  systemd.timers.claude-window-anchor = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = [ "*-*-* 07:00:00" "*-*-* 12:00:00" "*-*-* 17:00:00" ];
      # Catch-up after a reboot is safe: the script skips pings outside 07:00–20:00.
      Persistent = true;
    };
  };
}
