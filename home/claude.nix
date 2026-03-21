{ config, lib, pkgs, ... }:
let
  tokenPath = config.age.secrets.telegram-bot-token.path;

  notifyScript = pkgs.writeShellScript "claude-telegram-notify" ''
    CHAT_ID="82389391"
    TOKEN_FILE="${tokenPath}"
    [[ -f "$TOKEN_FILE" ]] || exit 0
    BOT_TOKEN=$(cat "$TOKEN_FILE")
    [[ -z "$BOT_TOKEN" ]] && exit 0

    PAYLOAD=$(cat)
    MESSAGE=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.message // empty')
    CWD=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.cwd // ""')
    PROJECT=$(basename "$CWD")

    if [[ -n "$MESSAGE" ]]; then
      TEXT="🤖 *Claude Code* — $PROJECT
    $MESSAGE"
    else
      TEXT="🤖 *Claude Code* is waiting for input
    📁 $PROJECT"
    fi

    ${pkgs.curl}/bin/curl -s -X POST \
      "https://api.telegram.org/bot''${BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=''${CHAT_ID}" \
      --data-urlencode "text=''${TEXT}" \
      --data-urlencode "parse_mode=Markdown" \
      > /dev/null
    exit 0
  '';

  claudeSettings = builtins.toJSON {
    effortLevel = "medium";
    skipDangerousModePermissionPrompt = true;
    permissions = {
      allow = [ "Bash(*)" "Read(*)" "Write(*)" "Edit(*)" "Glob(*)" "Grep(*)" "WebFetch(*)" "WebSearch(*)" "NotebookEdit(*)" "Task(*)" ];
      deny = [];
    };
    trustAll = true;
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
in
{
  home.file.".claude/settings.json" = {
    text = claudeSettings;
    force = true;
  };
}
