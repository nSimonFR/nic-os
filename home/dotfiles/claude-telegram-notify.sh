#!/usr/bin/env bash
# Claude Code → Telegram notification hook
# Fires on: Notification (idle_prompt / permission_prompt)
# Credentials: set CLAUDE_TELEGRAM_BOT_TOKEN and CLAUDE_TELEGRAM_CHAT_ID in secrets.zsh

CHAT_ID="82389391"

TOKEN_FILE="${XDG_RUNTIME_DIR}/agenix/telegram-bot-token"
[[ -f "$TOKEN_FILE" ]] || exit 0
BOT_TOKEN=$(cat "$TOKEN_FILE")

[[ -z "$BOT_TOKEN" ]] && exit 0

# Read hook payload from stdin
PAYLOAD=$(cat)

MESSAGE=$(echo "$PAYLOAD" | jq -r '.message // empty')
CWD=$(echo "$PAYLOAD" | jq -r '.cwd // ""')
PROJECT=$(basename "$CWD")

if [[ -n "$MESSAGE" ]]; then
    TEXT="🤖 *Claude Code* — $PROJECT
$MESSAGE"
else
    TEXT="🤖 *Claude Code* is waiting for input
📁 $PROJECT"
fi

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${TEXT}" \
    --data-urlencode "parse_mode=Markdown" \
    > /dev/null

exit 0
