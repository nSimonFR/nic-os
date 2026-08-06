#!/usr/bin/env bash
# telegram-send — post ONE message (or photo) to Telegram. See shared/notify.nix
# for when this is the wrong seam.
#
# Usage: telegram-send [-c CHAT] [-m html|markdown|plain] [-p PHOTO] [TEXT]
#   TEXT is read from stdin when omitted; with -p it becomes the caption.
# Env:   TELEGRAM_CHAT_ID, TELEGRAM_TOKEN_FILE (defaults to the agenix path,
#        then the per-user runtime one).
#
# Prints the raw API response so a caller can check `.ok`, and always exits 0 —
# a notification must never fail its caller.
set -u

chat=${TELEGRAM_CHAT_ID:-}
mode=html
photo=
text=

while [ $# -gt 0 ]; do
  case $1 in
    -c|--chat)  chat=$2;  shift 2 ;;
    -m|--mode)  mode=$2;  shift 2 ;;
    -p|--photo) photo=$2; shift 2 ;;
    -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
    *)          text=$1;  shift ;;
  esac
done
# Guard on a tty so an interactive call with no arguments errors instead of hanging.
[ -n "$text" ] || [ -t 0 ] || text=$(cat)

die() { echo "telegram-send: $1" >&2; exit 0; }

# An explicit TELEGRAM_TOKEN_FILE is authoritative — never silently fall back to
# a different credential. The defaults are only for callers that set nothing.
for f in ${TELEGRAM_TOKEN_FILE:-/run/agenix/telegram-bot-token \
         "/run/user/$(id -u)/agenix/telegram-bot-token"}; do
  [ -r "$f" ] && { token=$(< "$f"); break; }
done
[ -n "${token:-}" ] || die "no readable bot token"
[ -n "$chat" ] || die "no chat id (pass --chat or set TELEGRAM_CHAT_ID)"

# `plain` omits parse_mode entirely — Telegram rejects an empty one.
case $mode in
  html)     set -- -d parse_mode=HTML ;;
  markdown) set -- -d parse_mode=Markdown ;;
  plain)    set -- ;;
  *)        die "unknown --mode $mode" ;;
esac

if [ -n "$photo" ]; then
  [ -r "$photo" ] || die "photo unreadable ($photo)"
  method=sendPhoto
  set -- "$@" -F "chat_id=$chat" -F "photo=@$photo"
  [ -n "$text" ] && set -- "$@" -F "caption=$text"
else
  [ -n "$text" ] || die "empty message body"
  method=sendMessage
  # --data-urlencode keeps newlines, spaces and punctuation intact.
  set -- "$@" -d "chat_id=$chat" -d disable_web_page_preview=true \
              --data-urlencode "text=$text"
fi

resp=$(curl -sS --max-time 20 -X POST \
  "https://api.telegram.org/bot$token/$method" "$@" 2>&1)
printf '%s\n' "$resp"
case $resp in *'"ok":true'*) ;; *) die "send rejected: $resp" ;; esac
