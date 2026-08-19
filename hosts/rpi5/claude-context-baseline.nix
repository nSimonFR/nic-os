# Alert when new Claude Code sessions start with too much baseline context.
#
# A session's baseline is what its FIRST request costs before any work happens
# (system prompt + CLAUDE.md + tool/MCP schemas + skills). On 2026-08-17 MCP
# schemas stopped being deferred behind ToolSearch — server-side, on an unchanged
# client — and bridge sessions went from ~50k to ~134k against a 200k window.
# Nothing failed, no unit went red, and the only symptom was sessions compacting
# every few tool calls; it took a transcript-archaeology session to find. This
# hourly oneshot turns that class of regression into a page.
#
# It complements rather than duplicates the `deniedMcpServers` entries in
# .claude/settings.json: those pin the four connectors already known to be
# expensive. A new connector, a new plugin, a fatter CLAUDE.md, or the next
# upstream deferral change all move the baseline without touching that file.
#
# On-demand check: sudo systemctl start claude-context-baseline
#                  (then journalctl -u claude-context-baseline -n 5)
# See the `claude-context-baseline` entry point of the nicos-scripts package
# (hosts/rpi5/scripts/lib/nicos_scripts/claude/context_baseline.py).
{ config, pkgs, telegramChatId, ... }:
let
  # The self-updating alerter (send-once / edit-in-place / resolve), same seam as
  # monitoring.nix. Correct here rather than the one-shot `send` because this is a
  # condition that CLEARS: deny the offending connector, the next session's
  # baseline drops, and the following empty body resolves the message.
  telegramAlert = (import ../../shared/notify.nix { inherit pkgs; }).alert {
    tokenFile = config.age.secrets.telegram-bot-token.path;
    chatId = telegramChatId;
    name = "telegram-alert-context-baseline";
  };
in
{
  systemd.services.claude-context-baseline = {
    description = "Alert when Claude sessions start with too much baseline context";
    # Runs as root: the transcripts under /home/nsimon/.claude/projects are the
    # user's, and the bot token is an age secret readable only by root. Hence no
    # ProtectHome — reading $HOME is the entire job.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nicos-scripts}/bin/claude-context-baseline";
      NoNewPrivileges = true;
      Environment = [
        "CTXB_PROJECTS_DIR=/home/nsimon/.claude/projects"
        # 100k of a 200k window leaves half the context for actual work. The
        # observed states are ~50k (healthy) and ~134k (broken), so this sits in
        # the empty middle — far from both, and it does not need re-tuning if the
        # healthy baseline drifts by a few thousand tokens.
        "CTXB_THRESHOLD=100000"
        # One timer period plus slack, so a late run still covers the gap.
        "CTXB_LOOKBACK=5400"
        "CTXB_ALERT=${telegramAlert}"
        "CTXB_DRY_RUN=0"
      ];
    };
  };

  systemd.timers.claude-context-baseline = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 15min after boot: the bridge starts at 1min and its anchor session needs
      # to have made its first request before there is anything to measure.
      OnBootSec = "15min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
