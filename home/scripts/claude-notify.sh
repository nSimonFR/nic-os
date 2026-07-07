#!/usr/bin/env bash
# Unified Claude Code -> Telegram notification gate. One script, three modes
# (passed as $1) so the POST-to-aggregator logic lives in exactly one place:
#
#   activity      UserPromptSubmit hook. Stamps "the user is present right now"
#                 into ~/.claude/state/last-activity. No forward.
#   notification  Notification hook. Forwards to the central Telegram aggregator
#                 (rpi5/claude-notify-aggregator.py) ONLY if the user has been
#                 idle for >= CLAUDE_IDLE_NOTIFY_SECONDS. While the user is
#                 actively working these are dropped, killing routine spam.
#   push          PostToolUse(PushNotification) hook. Always forwards, flagged
#                 immediate so the aggregator flushes at once — this is the
#                 channel Claude uses when it decides an interruption is worth it.
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
  message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null)
  source="Claude Code"
  immediate="false"
elif [ "$mode" = "push" ]; then
  message=$(printf '%s' "$payload" | jq -r '.tool_input.message // empty' 2>/dev/null)
  source="Claude PushNotification"
  immediate="true"
else
  exit 0
fi

cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
project=$(basename "${cwd:-unknown}")
host=$(uname -n)

body=$(jq -nc \
  --arg host "$host" \
  --arg project "$project" \
  --arg message "$message" \
  --arg source "$source" \
  --argjson immediate "$immediate" \
  '{host:$host, project:$project, message:$message, source:$source, immediate:$immediate}')

# rpi5 hits the aggregator on loopback; other hosts fall back to the tailnet
# FQDN. -m 4 bounds the wait so the hook can't hang the agent.
for url in "http://127.0.0.1:8088/notify" "https://rpi5.gate-mintaka.ts.net:8088/notify"; do
  if curl -fsS -m 4 -X POST "$url" \
       -H 'Content-Type: application/json' \
       --data-raw "$body" >/dev/null 2>&1; then
    break
  fi
done
exit 0
