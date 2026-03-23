{
  config,
  pkgs,
  unstablePkgs,
  telegramChatId,
  ...
}:
let
  tokenPath = config.age.secrets.telegram-bot-token.path;

  notifyScript = pkgs.writeShellScript "claude-telegram-notify" ''
    CHAT_ID="${builtins.toString telegramChatId}"
    TOKEN_FILE="${tokenPath}"
    [[ -f "$TOKEN_FILE" ]] || TOKEN_FILE="/run/user/$(id -u)/agenix/telegram-bot-token"
    [[ -f "$TOKEN_FILE" ]] || exit 0
    BOT_TOKEN=$(cat "$TOKEN_FILE")
    [[ -z "$BOT_TOKEN" ]] && exit 0

    PAYLOAD=$(cat)
    MESSAGE=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.message // empty')
    CWD=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.cwd // ""')
    PROJECT=$(basename "$CWD")

    if [[ -n "$MESSAGE" ]]; then
      NOTIF_LINE="📁 $PROJECT: $MESSAGE"
    else
      NOTIF_LINE="📁 $PROJECT: waiting for input"
    fi

    # Aggregate notifications within a 60s window into one Telegram message
    STATE_DIR="/tmp/claude-notify-state"
    LOCK_DIR="$STATE_DIR/lock"
    STATE_FILE="$STATE_DIR/state"
    WINDOW=60

    mkdir -p "$STATE_DIR"

    # Acquire lock via mkdir (atomic on macOS/Linux)
    ATTEMPTS=0
    until mkdir "$LOCK_DIR" 2>/dev/null; do
      sleep 0.1
      ATTEMPTS=$((ATTEMPTS + 1))
      [[ $ATTEMPTS -gt 40 ]] && exit 0
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

    NOW=$(date +%s)
    MSG_ID=""
    LAST_TS=0

    if [[ -f "$STATE_FILE" ]]; then
      MSG_ID=$(sed -n '1p' "$STATE_FILE")
      LAST_TS=$(sed -n '2p' "$STATE_FILE")
    fi

    ELAPSED=$((NOW - ''${LAST_TS:-0}))

    if [[ -n "$MSG_ID" && $ELAPSED -lt $WINDOW ]]; then
      # Append to existing message
      PREV_LINES=$(tail -n +3 "$STATE_FILE")
      NEW_TEXT="🤖 *Claude Code*
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
      # Send a new message
      NEW_TEXT="🤖 *Claude Code*
''${NOTIF_LINE}"

      RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST \
        "https://api.telegram.org/bot''${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=''${CHAT_ID}" \
        --data-urlencode "text=''${NEW_TEXT}" \
        --data-urlencode "parse_mode=Markdown")

      NEW_MSG_ID=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.result.message_id // empty')
      [[ -n "$NEW_MSG_ID" ]] && { echo "$NEW_MSG_ID"; echo "$NOW"; echo "$NOTIF_LINE"; } > "$STATE_FILE"
    fi

    exit 0
  '';
in
{
  home.sessionVariables.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";

  programs.claude-code = {
    enable = true;
    package = unstablePkgs.claude-code;

    settings = {
      effortLevel = "medium";
      skipDangerousModePermissionPrompt = true;
      trustAll = true;
      permissions = {
        allow = [
          "Bash(*)"
          "Read(*)"
          "Write(*)"
          "Edit(*)"
          "Glob(*)"
          "Grep(*)"
          "WebFetch(*)"
          "WebSearch(*)"
          "NotebookEdit(*)"
          "Task(*)"
        ];
        deny = [ ];
      };
      hooks = {
        Notification = [
          {
            matcher = "";
            hooks = [
              {
                type = "command";
                command = "${notifyScript}";
                timeout = 10;
              }
            ];
          }
        ];
      };
    };
  };
}
