{
  config,
  pkgs,
  unstablePkgs,
  ...
}:
let
  telegram = import ../shared/telegram.nix;
  tokenPath = config.age.secrets.telegram-bot-token.path;

  notifyScript = pkgs.writeShellScript "claude-telegram-notify" ''
    CHAT_ID="${builtins.toString telegram.chatId}"
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
