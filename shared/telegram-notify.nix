# Shared Telegram notify hook used by both Claude Code (settings.json hook)
# and pi-coding-agent (TS extension shell-out).
#
# Reads JSON `{message?, cwd?}` on stdin; aggregates lines fired within
# `windowSeconds` into a single Telegram message via editMessageText.
{
  pkgs,
  telegramChatId,
}:
{
  name,
  header,
  stateDir,
  tokenPath,
  windowSeconds ? 60,
}:
pkgs.writeShellScript "${name}-telegram-notify" ''
  CHAT_ID="${builtins.toString telegramChatId}"

  # Token candidates: eval-time path → HM-context agenix → system-context agenix
  for candidate in "${tokenPath}" "/run/user/$(id -u)/agenix/telegram-bot-token" "/run/agenix/telegram-bot-token"; do
    if [[ -f "$candidate" ]]; then
      TOKEN_FILE="$candidate"
      break
    fi
  done
  [[ -z "''${TOKEN_FILE:-}" ]] && exit 0
  BOT_TOKEN=$(cat "$TOKEN_FILE")
  [[ -z "$BOT_TOKEN" ]] && exit 0

  PAYLOAD=$(cat)
  MESSAGE=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.message // empty')
  CWD=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.cwd // ""')
  PROJECT=$(basename "$CWD")
  NOTIF_LINE="📁 $PROJECT: ''${MESSAGE:-waiting for input}"

  STATE_DIR="${stateDir}"
  LOCK_DIR="$STATE_DIR/lock"
  STATE_FILE="$STATE_DIR/state"
  WINDOW=${builtins.toString windowSeconds}

  mkdir -p "$STATE_DIR"

  # mkdir is atomic on macOS/Linux; bound retries so a stale lock can't wedge.
  ATTEMPTS=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.1
    ATTEMPTS=$((ATTEMPTS + 1))
    [[ $ATTEMPTS -gt 40 ]] && exit 0
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT TERM INT HUP

  NOW=$(date +%s)
  MSG_ID=""
  LAST_TS=0
  if [[ -f "$STATE_FILE" ]]; then
    MSG_ID=$(sed -n '1p' "$STATE_FILE")
    LAST_TS=$(sed -n '2p' "$STATE_FILE")
  fi
  ELAPSED=$((NOW - ''${LAST_TS:-0}))

  if [[ -n "$MSG_ID" && $ELAPSED -lt $WINDOW ]]; then
    PREV_LINES=$(tail -n +3 "$STATE_FILE")
    NEW_TEXT="${header}
''${PREV_LINES}
''${NOTIF_LINE}"
    ${pkgs.curl}/bin/curl -s -X POST \
      "https://api.telegram.org/bot''${BOT_TOKEN}/editMessageText" \
      --data-urlencode "chat_id=''${CHAT_ID}" \
      --data-urlencode "message_id=''${MSG_ID}" \
      --data-urlencode "text=''${NEW_TEXT}" \
      --data-urlencode "parse_mode=Markdown" \
      > /dev/null
    { echo "$MSG_ID"; echo "$NOW"; echo "$PREV_LINES"; echo "$NOTIF_LINE"; } > "$STATE_FILE"
  else
    NEW_TEXT="${header}
''${NOTIF_LINE}"
    RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST \
      "https://api.telegram.org/bot''${BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=''${CHAT_ID}" \
      --data-urlencode "text=''${NEW_TEXT}" \
      --data-urlencode "parse_mode=Markdown")
    NEW_MSG_ID=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.result.message_id // empty')
    [[ -n "$NEW_MSG_ID" ]] && { echo "$NEW_MSG_ID"; echo "$NOW"; echo "$NOTIF_LINE"; } > "$STATE_FILE"
  fi
''
