#!/usr/bin/env bash
# Tests for the two scripted notification seams (see shared/notify.nix):
# rpi5/scripts/telegram-alert.sh's incident lifecycle, and telegram-send.sh.
#
# Offline: a stub `curl` earlier on PATH logs one line per call (newlines folded
# to '|') and replies with a canned Bot API response, so nothing reaches
# Telegram and no real token is needed.
#
# Run:  shared/scripts/tests/notify.test.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$*" | tr '\n' '|' >> "$CALL_LOG"; printf '\n' >> "$CALL_LOG"
default='{"ok":true,"result":{"message_id":'"${STUB_MESSAGE_ID:-4242}"'}}'
printf '%s\n' "${STUB_RESPONSE:-$default}"
STUB
chmod +x "$tmp/bin/curl"
printf 'fake-token\n' > "$tmp/token"
printf 'not-really-a-jpeg\n' > "$tmp/pic.jpg"

export PATH="$tmp/bin:$PATH" CALL_LOG="$tmp/calls"
export TELEGRAM_TOKEN_FILE="$tmp/token" TELEGRAM_CHAT_ID=1234567
: > "$CALL_LOG"

fails=0
ok()  { printf 'ok   — %s\n' "$1"; }
bad() { printf 'FAIL — %s\n       %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2], got [$3]"; }
sent() { tail -n 1 "$CALL_LOG"; }
has()  { case "$(sent)" in *"$2"*) ok "$1" ;; *) bad "$1" "want [$2] in: $(sent)" ;; esac; }
hasnt() { case "$(sent)" in *"$2"*) bad "$1" "unwanted [$2] in: $(sent)" ;; *) ok "$1" ;; esac; }
nth()  { sed -n "$1p" "$CALL_LOG"; }
count() { wc -l < "$CALL_LOG" | tr -d ' '; }

echo "── telegram-alert.sh: incident lifecycle ─────────────────────────────"
export ALERT_STATE_DIR="$tmp/state"
alert=$here/../../../rpi5/scripts/telegram-alert.sh
fire() { printf '%s' "$1" | bash "$alert" disk-full "🔴 Disk full"; }

fire "root 96%"
has "first firing sends"      "/sendMessage"
eq  "exactly one call"        1    "$(count)"
eq  "message id persisted"    4242 "$(cat "$ALERT_STATE_DIR/disk-full.mid")"
has "title in the body"       "text=<b>🔴 Disk full</b>"

fire "root 97%"; fire "root 98%"
case "$(nth 2)$(nth 3)" in
  *editMessageText*editMessageText*) ok "still-firing ticks edit in place" ;;
  *) bad "still-firing ticks edit in place" "$(nth 2) / $(nth 3)" ;;
esac
eq  "counter bumped"          3 "$(cat "$ALERT_STATE_DIR/disk-full.cnt")"
has "occurrence count shown"  "ongoing ×3"
has "edits the original"      "message_id=4242"

fire ""
has "clearing edits"          "editMessageText"
has "resolve marker sent"     "✅ resolved"
[ -e "$ALERT_STATE_DIR/disk-full.mid" ] \
  && bad "state cleared on resolve" "mid file survived" || ok "state cleared on resolve"

before=$(count); fire ""; fire ""
eq  "clear-while-clear is silent" "$before" "$(count)"

STUB_MESSAGE_ID=9999 fire "root 99%"
has "re-fire opens a new message" "/sendMessage"
eq  "new id stored"           9999 "$(cat "$ALERT_STATE_DIR/disk-full.mid")"
eq  "counter reset"           1    "$(cat "$ALERT_STATE_DIR/disk-full.cnt")"

printf 'oom' | bash "$alert" memory "🔴 OOM"
has "a second key is independent" "/sendMessage"
eq  "first key untouched"     9999 "$(cat "$ALERT_STATE_DIR/disk-full.mid")"

echo
echo "── telegram-send.sh: one-shot sender ─────────────────────────────────"
send=$here/../telegram-send.sh

bash "$send" "hello" >/dev/null
has "posts sendMessage"       "/botfake-token/sendMessage"
has "chat id from env"        "chat_id=1234567"
has "defaults to HTML"        "parse_mode=HTML"
has "suppresses link preview" "disable_web_page_preview=true"
has "urlencodes the text"     "text=hello"

bash "$send" --mode plain "raw <text> & more" >/dev/null
hasnt "plain omits parse_mode" "parse_mode"
has  "plain keeps the body"    "text=raw <text> & more"

bash "$send" --mode markdown "*bold*" >/dev/null
has "markdown maps to Markdown" "parse_mode=Markdown"

bash "$send" --chat -100999 "grouped" >/dev/null
has "explicit --chat wins"    "chat_id=-100999"

printf 'line one\nline two' | bash "$send" >/dev/null
has "reads the body from stdin" "text=line one|line two"

bash "$send" --photo "$tmp/pic.jpg" "a caption" >/dev/null
has "photo posts sendPhoto"   "/sendPhoto"
has "photo attached"          "photo=@$tmp/pic.jpg"
has "text becomes the caption" "caption=a caption"

case "$(bash "$send" "hi")" in
  *'"message_id":4242'*) ok "prints the API response" ;;
  *) bad "prints the API response" "got: $(bash "$send" "hi")" ;;
esac

before=$(count)
STUB_RESPONSE='{"ok":false,"description":"chat not found"}' bash "$send" x >/dev/null 2>&1
eq "a rejected send still exits 0" 0 $?
TELEGRAM_TOKEN_FILE=$tmp/nope bash "$send" x >/dev/null 2>&1
eq "a missing token exits 0"       0 $?
TELEGRAM_CHAT_ID= bash "$send" x >/dev/null 2>&1
eq "a missing chat id exits 0"     0 $?
eq "neither dialled out"           $((before + 1)) "$(count)"

echo
[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit $(( fails > 0 ))
