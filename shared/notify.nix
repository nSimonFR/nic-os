# The three notification seams. Pick by lifecycle, not by convenience:
#
#   alert  a condition that fires and later CLEARS — one self-updating message
#          per incident (send-once, edit-in-place, occurrence count, `since`,
#          auto-resolve).            → rpi5/scripts/telegram-alert.sh
#   send   a one-shot event with no resolved state.
#                                    → shared/scripts/telegram-send.sh
#   agent  agent chatter that should batch — POSTs to rpi5's :8088 aggregator,
#          which owns the token and the debouncing.
#                                    → shared/scripts/agent-notify.sh
#
# Routing a one-shot through `alert` leaves a message stuck at "⚠ ongoing"
# forever (nothing ever calls back with an empty body); routing a pre-reboot
# ping through `agent` debounces it for up to 15 min. Hence three, not one.
#
# Usage:  notify = import ../shared/notify.nix { inherit pkgs; };
#         printf '%s' "$body" | ${notify.alert { inherit tokenFile chatId; }} <key> "<title>"
{ pkgs }:
let
  inherit (pkgs) lib;
  path = drvs: "${lib.makeBinPath drvs}\${PATH:+:$PATH}";
in
{
  alert =
    { tokenFile, chatId, name ? "telegram-alert", stateDir ? "/var/lib/telegram-alerts" }:
    pkgs.writeShellScript name ''
      export TELEGRAM_TOKEN_FILE=${tokenFile}
      export TELEGRAM_CHAT_ID=${toString chatId}
      export ALERT_STATE_DIR=${stateDir}
      export PATH=${path [ pkgs.curl pkgs.jq pkgs.coreutils ]}
      exec ${pkgs.bash}/bin/bash ${../rpi5/scripts/telegram-alert.sh} "$@"
    '';

  send =
    { tokenFile, chatId, name ? "telegram-send" }:
    pkgs.writeShellScript name ''
      export TELEGRAM_TOKEN_FILE=${tokenFile}
      export TELEGRAM_CHAT_ID=${toString chatId}
      export PATH=${path [ pkgs.curl pkgs.coreutils ]}
      exec ${pkgs.bash}/bin/bash ${./scripts/telegram-send.sh} "$@"
    '';

  # `source` is baked in unless null — home/scripts/claude-notify.sh varies it
  # per invocation and passes its own.
  agent =
    { name, source ? null }:
    pkgs.writeShellScript "${name}-agent-notify" ''
      export PATH=${path [ pkgs.curl pkgs.jq pkgs.coreutils ]}
      exec ${pkgs.bash}/bin/bash ${./scripts/agent-notify.sh} ${
        lib.optionalString (source != null) "--source ${lib.escapeShellArg source}"
      } "$@"
    '';
}
