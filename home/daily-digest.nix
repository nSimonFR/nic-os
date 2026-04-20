{
  config,
  pkgs,
  telegramChatId,
  ...
}:
let
  tokenPath = config.age.secrets.telegram-bot-token.path;

  digestScript = pkgs.writeShellScript "daily-telegram-digest" ''
    set -euo pipefail

    # Pure nix-path bins (always available) + home-manager's bin dir so the
    # gh/gog/blogwatcher binaries (installed by home-manager, not nixpkgs)
    # resolve via `command -v`. Same pattern as picoclaw's exec wrapper.
    export PATH=${pkgs.lib.makeBinPath [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
      pkgs.gawk
      pkgs.gnugrep
      pkgs.findutils
      pkgs.curl
      pkgs.jq
      pkgs.git
    ]}:$HOME/.local/state/nix/profiles/home-manager/home-path/bin

    CHAT_ID="${builtins.toString telegramChatId}"
    TOKEN_FILE="${tokenPath}"
    [[ -f "$TOKEN_FILE" ]] || TOKEN_FILE="/run/user/$(id -u)/agenix/telegram-bot-token"
    [[ -f "$TOKEN_FILE" ]] || exit 0
    BOT_TOKEN=$(cat "$TOKEN_FILE")
    [[ -n "$BOT_TOKEN" ]] || exit 0

    TODAY=$(date +%F)
    NOW_HUMAN=$(date '+%A %d %B %Y')
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    BLOGWATCHER_BIN=$(command -v blogwatcher || true)
    GH_BIN=$(command -v gh || true)
    GOG_BIN=$(command -v gog || true)
    [[ -n "$GH_BIN" && -n "$GOG_BIN" ]] || exit 1

    # Calendar
    FROM="$(date -Iseconds)"
    TO="$(date -d 'tomorrow 00:00:00' -Iseconds)"
    "$GOG_BIN" calendar events primary --from "$FROM" --to "$TO" --json --no-input > "$TMPDIR/calendar.json"

    # Blogwatcher
    if [[ -n "$BLOGWATCHER_BIN" ]]; then
      "$BLOGWATCHER_BIN" scan >/dev/null 2>&1 || true
      "$BLOGWATCHER_BIN" articles > "$TMPDIR/blogwatcher.txt" || true
    else
      : > "$TMPDIR/blogwatcher.txt"
    fi

    # GitHub notifications
    "$GH_BIN" api notifications > "$TMPDIR/gh_notifications.json" || printf '[]\n' > "$TMPDIR/gh_notifications.json"

    MESSAGE=$(
      TODAY="$TODAY" NOW_HUMAN="$NOW_HUMAN" jq -rn \
        --slurpfile cal "$TMPDIR/calendar.json" \
        --rawfile blog "$TMPDIR/blogwatcher.txt" \
        --slurpfile gh "$TMPDIR/gh_notifications.json" '
          def events: ($cal[0].events // []);
          def same_day(ev):
            if ev.start.date? then ev.start.date == env.TODAY
            elif ev.start.dateTime? then (ev.start.dateTime[0:10] == env.TODAY)
            else false end;
          def fmt_time(ev):
            if ev.start.dateTime? and ev.end.dateTime? then
              ((ev.start.dateTime | strptime("%Y-%m-%dT%H:%M:%S%z") | strftime("%H:%M")) + "–" +
               (ev.end.dateTime   | strptime("%Y-%m-%dT%H:%M:%S%z") | strftime("%H:%M")))
            elif ev.start.dateTime? then
              (ev.start.dateTime | strptime("%Y-%m-%dT%H:%M:%S%z") | strftime("%H:%M"))
            else
              "all-day"
            end;
          def fmt_event(ev):
            "• " + (ev.summary // "(no title)")
            + (if (ev.start.dateTime? or ev.end.dateTime?) then " — " + fmt_time(ev) else "" end)
            + (if ev.location? then " — " + ev.location else "" end);
          def blog_lines:
            ($blog
              | split("\n")
              | map(select(length > 0))
              | map(select(startswith("  [") and (contains("[read]") | not)))
              | map(sub("^  "; "• ")));
          def gh_lines:
            ($gh[0] // [])
            | map("• [" + (.repository.full_name // "?") + "] " + (.subject.title // "(no title)") + " (" + (.subject.type // "?") + ")");
          "🗓 *Daily digest — " + env.NOW_HUMAN + "*\n\n"
          + "*Today’s events*\n"
          + ([(events[] | select(same_day(.)) | fmt_event(.))] | if length == 0 then "• No events" else join("\n") end)
          + "\n\n*Blogwatcher unread*\n"
          + (blog_lines | if length == 0 then "• No unread articles" else join("\n") end)
          + "\n\n*GitHub notifications*\n"
          + (gh_lines | if length == 0 then "• No notifications" else (.[0:10] | join("\n")) end)
        '
    )

    curl -fsS -X POST \
      "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=$CHAT_ID" \
      --data-urlencode "text=$MESSAGE" \
      --data-urlencode "parse_mode=Markdown" \
      > /dev/null
  '';
in
{
  systemd.user.services.daily-telegram-digest = {
    Unit = {
      Description = "Daily Telegram digest with calendar, blogwatcher, and GitHub notifications";
      After = [ "network-online.target" "agenix.service" ];
      Wants = [ "network-online.target" "agenix.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${digestScript}";
    };
  };

  systemd.user.timers.daily-telegram-digest = {
    Unit = {
      Description = "Run daily Telegram digest at 08:30";
    };
    Timer = {
      OnCalendar = "*-*-* 08:30:00";
      Persistent = true;
      Unit = "daily-telegram-digest.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
