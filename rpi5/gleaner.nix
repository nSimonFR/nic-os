{ config, lib, pkgs, inputs, telegramChatId, ... }:

let
  telegramNotify = pkgs.writeShellScript "gleaner-telegram-notify" ''
    TOKEN=$(< ${config.age.secrets.telegram-bot-token.path})
    MSG="$1"
    ${pkgs.curl}/bin/curl -sf -X POST \
      "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id=${toString telegramChatId} \
      -d parse_mode=HTML \
      -d text="$MSG"
  '';

  dispatcherHook = pkgs.writeShellScript "gleaner-hook-dispatch" ''
    EVENT="$1"
    PAYLOAD=$(cat)
    case "$EVENT" in
      pr_opened)
        URL=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r .pr.url)
        PROFILE=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r .profile)
        ${telegramNotify} "<b>Gleaner</b> opened <a href=\"$URL\">PR</a> via $PROFILE"
        ;;
      dispatch_failed)
        REASON=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r .reason)
        ${telegramNotify} "<b>Gleaner dispatch failed:</b> $REASON"
        ;;
      quota_cap_hit)
        ${telegramNotify} "<b>Gleaner:</b> quota ceiling hit; pausing dispatch"
        ;;
    esac
  '';
in {
  imports = [ inputs.gleaner.nixosModules.gleaner ];

  # Single dispatch hook the gleaner config points at. nic-os owns the
  # routing to Telegram; gleaner emits provider-agnostic event payloads.
  environment.etc."gleaner/hooks/dispatch.sh" = {
    mode = "0755";
    source = dispatcherHook;
  };

  # The user account that owns ~/.claude/projects and ~/.codex/sessions
  # is `nsimon`. gleaner.service runs as that user so it can read the
  # local journals + the OAuth credentials file.
  services.gleaner = {
    enable     = true;
    user       = "nsimon";
    configFile = ./gleaner.config.yaml;
    workTreeRoot = "/var/lib/gleaner/worktrees";
    timer.onUnitActiveSec = "10min";
    timer.persistent = true;
  };

  # nsimon-owned worktree root; gleaner.service creates it via
  # StateDirectory but ownership defaults to root if pre-existing.
  systemd.tmpfiles.rules = [
    "d /var/lib/gleaner            0755 nsimon users -"
    "d /var/lib/gleaner/worktrees  0755 nsimon users -"
  ];
}
