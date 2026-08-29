#!/usr/bin/env bash
set -euo pipefail

PATH=/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}
WORKDIR=${WORKDIR:-/home/nsimon/.hermes/workspace}
TMPDIR=${TMPDIR:-$WORKDIR/tmp}
CHAT_ID=${TELEGRAM_CHAT_ID:-82389391}
MAX_GH=${MAX_GH:-20}
MAX_BW=${MAX_BW:-20}
DRY_RUN=0
NO_MARK_READ=0
RICH=0
RICH_LAYOUT=default

usage() {
  cat <<'USAGE'
Usage: daily-pending-digest.sh [--dry-run] [--no-mark-read] [--rich] [--rich-collapsible-all]

Collects GitHub notifications (excluding PRs) and BlogWatcher unread articles,
formats a Telegram digest, sends it, then marks included GitHub notifications
and BlogWatcher articles as read only after successful send.

--rich sends via Bot API sendRichMessage with native headings/collapsible sections;
the default remains compact sendMessage HTML.
--rich-collapsible-all uses collapsible GitHub and BlogWatcher sections; combine
with high MAX_GH/MAX_BW to display all items.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-mark-read) NO_MARK_READ=1 ;;
    --rich) RICH=1 ;;
    --rich-collapsible-all) RICH=1; RICH_LAYOUT=collapsible-all ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$TMPDIR"
GH_RAW="$TMPDIR/daily_pending_digest_gh_raw.json"
GH_ITEMS="$TMPDIR/daily_pending_digest_gh_items.json"
GH_INCLUDED_IDS="$TMPDIR/daily_pending_digest_included_ids.txt"
BW_RAW="$TMPDIR/daily_pending_digest_blogwatcher.out"
MSG_TXT="$TMPDIR/daily_pending_digest_message.txt"
MSG_RICH="$TMPDIR/daily_pending_digest_message.rich.html"
RICH_JSON="$TMPDIR/daily_pending_digest_rich_message.json"
MARK_LOG="$TMPDIR/daily_pending_digest_mark_read.log"
: >"$GH_INCLUDED_IDS"
: >"$MARK_LOG"

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

one_line() {
  tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

telegram_token() {
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    printf '%s' "$TELEGRAM_BOT_TOKEN"
  elif [ -n "${PICOCLAW_CHANNELS_TELEGRAM_TOKEN:-}" ]; then
    printf '%s' "$PICOCLAW_CHANNELS_TELEGRAM_TOKEN"
  elif [ -r /run/agenix/telegram-bot-token ]; then
    tr -d '\n' </run/agenix/telegram-bot-token
  else
    return 1
  fi
}

format_github() {
  if ! command -v gh >/dev/null 2>&1; then
    printf 'GitHub notifications excluding PRs:\n'
    printf '• error: gh not found\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'GitHub notifications excluding PRs:\n'
    printf '• error: jq not found\n'
    return 0
  fi

  local err="$TMPDIR/daily_pending_digest_gh.err"
  if ! gh api notifications --paginate >"$GH_RAW" 2>"$err"; then
    printf 'GitHub notifications excluding PRs:\n'
    printf '• error: %s\n' "$(one_line <"$err" | cut -c1-220 | html_escape)"
    return 0
  fi

  if ! jq -s '[.[][] | select(.subject.type != "PullRequest")]' "$GH_RAW" >"$GH_ITEMS" 2>"$err"; then
    printf 'GitHub notifications excluding PRs:\n'
    printf '• error: could not parse gh output\n'
    return 0
  fi

  local count extra
  count=$(jq 'length' "$GH_ITEMS")
  printf 'GitHub notifications excluding PRs:\n'
  if [ "$count" -eq 0 ]; then
    printf '• none\n'
    return 0
  fi

  jq -r --argjson max "$MAX_GH" '.[:$max][] | .id' "$GH_ITEMS" >"$GH_INCLUDED_IDS"
  # GitHub notifications expose Release subjects as API URLs ending in a numeric
  # release ID. Resolve those to their canonical public .html_url; converting the
  # number into /releases/tag/<id> produces invalid links.
  local resolved="$TMPDIR/daily_pending_digest_gh_resolved.json"
  jq -c --argjson max "$MAX_GH" '.[:$max][]' "$GH_ITEMS" |
    while IFS= read -r notification; do
      subject_type=$(jq -r '.subject.type' <<<"$notification")
      subject_url=$(jq -r '.subject.url' <<<"$notification")
      if [ "$subject_type" = "Release" ] && [[ "$subject_url" =~ ^https://api.github.com/repos/.*/releases/[0-9]+$ ]]; then
        if public_url=$(gh api "$subject_url" --jq '.html_url' 2>/dev/null) && [[ "$public_url" =~ ^https://github.com/ ]]; then
          jq --arg url "$public_url" '.subject.url = $url' <<<"$notification"
          continue
        fi
      fi
      jq '.' <<<"$notification"
    done | jq -s '.' >"$resolved"

  jq -r '
    .[] |
    "• <a href=\"" + (.subject.url
      | sub("^https://api.github.com/repos/"; "https://github.com/")
      | sub("/issues/"; "/issues/")
      | sub("/pulls/"; "/pull/")
    ) + "\">" + .repository.full_name + "</a> " + .subject.type + ": " + .subject.title
  ' "$resolved" | html_escape | sed 's/&lt;a href=/\<a href=/; s/&quot;/"/g; s/&gt;/\>/; s#&lt;/a&gt;#</a>#'

  if [ "$count" -gt "$MAX_GH" ]; then
    extra=$((count - MAX_GH))
    printf '… +%s more\n' "$extra"
  fi
}

format_blogwatcher() {
  printf 'BlogWatcher unread articles:\n'
  if ! command -v blogwatcher >/dev/null 2>&1; then
    printf '• error: blogwatcher not found\n'
    return 0
  fi

  blogwatcher scan >/dev/null 2>"$TMPDIR/daily_pending_digest_bw_scan.err" || true
  if ! blogwatcher articles >"$BW_RAW" 2>"$TMPDIR/daily_pending_digest_bw_articles.err"; then
    printf '• error: %s\n' "$(one_line <"$TMPDIR/daily_pending_digest_bw_articles.err" | cut -c1-220 | html_escape)"
    return 0
  fi

  if [ ! -s "$BW_RAW" ] || grep -qi 'No unread articles' "$BW_RAW"; then
    printf '• none\n'
    return 0
  fi

  if jq -e . "$BW_RAW" >/dev/null 2>&1; then
    local count
    count=$(jq 'if type=="array" then length else ((.articles // .items // []) | length) end' "$BW_RAW")
    if [ "$count" -eq 0 ]; then
      printf '• none\n'
      return 0
    fi
    jq -r --argjson max "$MAX_BW" '
      (if type=="array" then . else (.articles // .items // []) end) as $items |
      $items[:$max][] |
      "• " + (.title // "(untitled)") + " — " + (.feed_title // .blog // .blog_name // .source // "") + " — " + (.url // .link // "") + " — Published: " + ((.published // .published_at // .date // "") | tostring | split("T")[0])
    ' "$BW_RAW" | html_escape
    if [ "$count" -gt "$MAX_BW" ]; then
      printf '… +%s more\n' "$((count - MAX_BW))"
    fi
  else
    # Parse current blogwatcher human output into compact bullets.
    awk -v max="$MAX_BW" '
      BEGIN { shown=0; total=0 }
      /^[[:space:]]*\[[0-9]+\]/ {
        if (title != "") emit()
        line=$0
        sub(/^[[:space:]]*\[[0-9]+\][[:space:]]+\[[^]]+\][[:space:]]+/, "", line)
        title=line; blog=""; url=""; published=""; next
      }
      /^[[:space:]]*Blog:/ { blog=$0; sub(/^[[:space:]]*Blog:[[:space:]]*/, "", blog); next }
      /^[[:space:]]*URL:/ { url=$0; sub(/^[[:space:]]*URL:[[:space:]]*/, "", url); next }
      /^[[:space:]]*Published:/ { published=$0; sub(/^[[:space:]]*Published:[[:space:]]*/, "", published); next }
      function emit() {
        total++
        if (shown < max) {
          printf "• %s", title
          if (blog != "") printf " — %s", blog
          if (url != "") printf " — %s", url
          if (published != "") printf " — Published: %s", published
          printf "\n"
          shown++
        }
        title=""; blog=""; url=""; published=""
      }
      END {
        if (title != "") emit()
        if (total == 0) print "• none"
        else if (total > max) printf "… +%d more\n", total - max
      }
    ' "$BW_RAW" | html_escape
  fi
}

build_rich_message() {
  # Convert the existing compact digest into Telegram Rich HTML. Keep links from
  # format_github intact. Layout variants stay behind explicit flags.
  awk -v layout="$RICH_LAYOUT" '''
    function emit_p_end() { if (in_p) { print "</p>"; in_p=0 } }
    function close_details() { emit_p_end(); if (in_details) { print "</details>"; in_details=0 } }
    function emit_line(line) {
      if (!in_p) { printf "<p>"; in_p=1 } else { printf "<br/>" }
      printf "%s", line
    }
    NR == 1 { print "<h3>" $0 "</h3>"; next }
    NR == 2 { print "<footer>" $0 "</footer>"; next }
    $0 == "" { emit_p_end(); next }
    $0 == "GitHub notifications excluding PRs:" {
      close_details()
      if (layout == "collapsible-all") { print "<details open><summary>GitHub notifications excluding PRs</summary>"; in_details=1 }
      else { print "<h4>GitHub notifications excluding PRs</h4>" }
      next
    }
    $0 == "BlogWatcher unread articles:" {
      close_details()
      print "<details" (layout == "collapsible-all" ? " open" : "") "><summary>BlogWatcher unread articles</summary>"
      in_details=1
      next
    }
    { emit_line($0) }
    END { close_details() }
  ''' "$MSG_TXT" >"$MSG_RICH"
}

build_message() {
  {
    printf 'Daily pending digest\n'
    printf 'Generated: %s\n\n' "$(date '+%Y-%m-%d %H:%M %Z')"
    format_github
    printf '\n'
    format_blogwatcher
  } >"$MSG_TXT"
}

send_telegram() {
  local token
  token=$(telegram_token) || { echo "missing Telegram bot token" >&2; return 1; }
  local response="$TMPDIR/daily_pending_digest_telegram_response.json"

  if [ "$RICH" -eq 1 ]; then
    build_rich_message
    jq -n --rawfile html "$MSG_RICH" '{html: $html, skip_entity_detection: false}' >"$RICH_JSON"
    curl -fsS -X POST "https://api.telegram.org/bot${token}/sendRichMessage" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "rich_message@$RICH_JSON" \
      >"$response"
  else
    curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      -d parse_mode=HTML \
      --data-urlencode "text@$MSG_TXT" \
      >"$response"
  fi

  jq -e '.ok == true' "$response" >/dev/null 2>&1 || {
    echo "Telegram send failed: $(cat "$response")" >&2
    return 1
  }
}

mark_read() {
  [ "$NO_MARK_READ" -eq 0 ] || return 0

  if [ -s "$GH_INCLUDED_IDS" ] && command -v gh >/dev/null 2>&1; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if gh api -X PATCH "/notifications/threads/${id}" >/dev/null 2>&1; then
        printf 'github read: %s\n' "$id" >>"$MARK_LOG"
      else
        printf 'github read failed: %s\n' "$id" >>"$MARK_LOG"
      fi
    done <"$GH_INCLUDED_IDS"
  fi

  if command -v blogwatcher >/dev/null 2>&1; then
    if blogwatcher read-all --yes >/dev/null 2>&1; then
      printf 'blogwatcher read-all: ok\n' >>"$MARK_LOG"
    else
      printf 'blogwatcher read-all --yes: failed\n' >>"$MARK_LOG"
    fi
  fi
}

build_message
if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$RICH" -eq 1 ]; then
    build_rich_message
    cat "$MSG_RICH"
  else
    cat "$MSG_TXT"
  fi
  exit 0
fi
send_telegram
mark_read
printf 'sent daily pending digest; mark-read log: %s\n' "$MARK_LOG"
