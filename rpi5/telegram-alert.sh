#!/usr/bin/env bash
# Send-or-update a Telegram alert.
#
# Called by an alert service on every timer tick with the *current* alert body
# on stdin (an empty body means the condition has cleared). Instead of posting
# a fresh message each tick, the first firing sends one message and remembers
# its id; subsequent ticks edit that same message in place and bump an
# occurrence counter; once the body goes empty the message is edited to
# "resolved" and the stored state is cleared, so the next incident opens a new
# message. Net effect: one self-updating message per incident, no spam.
#
# Args:  $1 = state key (unique per alert)   $2 = title (HTML, static)
# Stdin: alert body (HTML). Empty / whitespace-only means "cleared".
# Env:   TELEGRAM_TOKEN_FILE  path to the bot token
#        TELEGRAM_CHAT_ID     chat to post in
#        ALERT_STATE_DIR      dir for per-alert state files
#        curl, jq, date, mkdir, rm, cat must be on PATH.
set -u

key=$1
title=$2
body=$(cat)

token=$(< "$TELEGRAM_TOKEN_FILE")
api="https://api.telegram.org/bot$token"
now=$(date '+%H:%M')

mkdir -p "$ALERT_STATE_DIR"
mid_f="$ALERT_STATE_DIR/$key.mid"
cnt_f="$ALERT_STATE_DIR/$key.cnt"
first_f="$ALERT_STATE_DIR/$key.first"

# tg METHOD TEXT [extra curl args...]
tg() {
  local method=$1 text=$2
  shift 2
  curl -sf -X POST "$api/$method" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode=HTML \
    -d disable_web_page_preview=true \
    "$@" \
    --data-urlencode "text=$text"
}

if [ -n "${body//[[:space:]]/}" ]; then
  # ── Condition is firing ──────────────────────────────────────────────────
  if [ -f "$mid_f" ]; then
    # Already have a live message → edit it and bump the counter.
    mid=$(< "$mid_f")
    cnt=$(( $(cat "$cnt_f" 2>/dev/null || echo 1) + 1 ))
    first=$(cat "$first_f" 2>/dev/null || echo "$now")
    printf '%s\n' "$cnt" > "$cnt_f"
    text="<b>$title</b>
$body

<i>⚠ ongoing ×$cnt · since $first · updated $now</i>"
    tg editMessageText "$text" -d message_id="$mid" > /dev/null || true
  else
    # First firing → send a fresh message and remember its id.
    text="<b>$title</b>
$body

<i>⚠ detected $now</i>"
    resp=$(tg sendMessage "$text" || true)
    mid=$(printf '%s' "$resp" | jq -r '.result.message_id // empty')
    if [ -n "$mid" ]; then
      printf '%s\n' "$mid"   > "$mid_f"
      printf '1\n'           > "$cnt_f"
      printf '%s\n' "$now"   > "$first_f"
    fi
  fi
else
  # ── Condition has cleared ────────────────────────────────────────────────
  if [ -f "$mid_f" ]; then
    mid=$(< "$mid_f")
    cnt=$(cat "$cnt_f" 2>/dev/null || echo '?')
    first=$(cat "$first_f" 2>/dev/null || echo '?')
    text="<b>$title</b>

<i>✅ resolved $now · was ongoing ×$cnt since $first</i>"
    tg editMessageText "$text" -d message_id="$mid" > /dev/null || true
    rm -f "$mid_f" "$cnt_f" "$first_f"
  fi
fi
