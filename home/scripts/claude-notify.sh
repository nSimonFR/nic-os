#!/usr/bin/env bash
# Unified Claude Code -> Telegram notification gate. One script, three modes
# (passed as $1) so the POST-to-aggregator logic lives in exactly one place:
#
#   activity      UserPromptSubmit hook. Stamps "the user is present right now"
#                 into ~/.claude/state/last-activity. No forward.
#   notification  Notification hook. Forwards to the central Telegram aggregator
#                 (hosts/rpi5/claude-notify-aggregator.py) ONLY if the user has been
#                 idle for >= CLAUDE_IDLE_NOTIFY_SECONDS. While the user is
#                 actively working these are dropped, killing routine spam.
#   push          PostToolUse(PushNotification) hook. Always forwards, flagged
#                 immediate so the aggregator flushes at once — this is the
#                 channel Claude uses when it decides an interruption is worth it.
#
# What this script owns is the *gating* (the activity clock and the idle
# threshold). Building the payload and POSTing it belongs to the shared
# aggregator seam, shared/scripts/agent-notify.sh, reached via $AGENT_NOTIFY —
# set by the writeShellScript wrapper in home/claude.nix that installs this as
# ~/.claude/hooks/claude-notify. That is the only entry point, so the variable
# is always set in practice; a missing one is logged rather than silently eaten.
#
# State (~/.claude/state) and this hooks dir are shared with the remote-control
# bridge (~/.claude-rc symlinks both back here), so interactive and remote
# sessions gate off the same activity clock.
#
# Always exits 0 — a hook must never block the agent.
set +e

STATE_DIR="${HOME}/.claude/state"
ACTIVITY_FILE="${STATE_DIR}/last-activity"
# "super idle" threshold; override with CLAUDE_IDLE_NOTIFY_SECONDS. Default 15m.
IDLE_THRESHOLD="${CLAUDE_IDLE_NOTIFY_SECONDS:-900}"

mode="$1"
now=$(date +%s)

if [ "$mode" = "activity" ]; then
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s' "$now" > "$ACTIVITY_FILE" 2>/dev/null
  exit 0
fi

payload=$(cat 2>/dev/null)

if [ "$mode" = "notification" ]; then
  # Idle gate. A missing stamp (no prompt yet on this host) fails open so we
  # never silently lose the first notification of a fresh session.
  if [ -f "$ACTIVITY_FILE" ]; then
    last=$(cat "$ACTIVITY_FILE" 2>/dev/null)
    [ -z "$last" ] && last=0
    if [ "$(( now - last ))" -lt "$IDLE_THRESHOLD" ]; then
      exit 0
    fi
  fi
  # `.message` is where the Notification hook puts its text…
  message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null)
  source="Claude Code"
  set --
elif [ "$mode" = "push" ]; then
  # …whereas PushNotification nests it under the tool input, so neither can be
  # left to agent-notify.sh's own `.message` default.
  message=$(printf '%s' "$payload" | jq -r '.tool_input.message // empty' 2>/dev/null)
  source="Claude PushNotification"
  set -- --immediate
else
  exit 0
fi

if [ -z "${AGENT_NOTIFY:-}" ] || [ ! -x "$AGENT_NOTIFY" ]; then
  echo "claude-notify: AGENT_NOTIFY unset or not executable; dropping notification" >&2
  exit 0
fi

# `cwd` is still read from the payload here rather than left to agent-notify.sh,
# because that stdin has already been consumed above.
printf '%s' "$payload" | "$AGENT_NOTIFY" --source "$source" --message "$message" "$@"
exit 0
