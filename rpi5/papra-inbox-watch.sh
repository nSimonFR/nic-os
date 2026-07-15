#!/usr/bin/env bash
# Multi-source feeder into Papra's ingestion drop-zone. Runs on a timer (polling)
# as root so it can read source files (Nextcloud-owned, picoclaw-dropped) and
# write the papra-owned ingestion dir.
#
# Sources: PAPRA_INBOXES is a colon-separated list of directories to scan
#   e.g. "/mnt/data/nextcloud/data/nsimon/files/Papra Inbox:/var/lib/papra/skill-inbox"
# Dest:   PAPRA_INBOX_DEST = /mnt/data/papra/ingestion/<orgId>
#
# Design choice: originals are LEFT IN PLACE and deduped by content hash in a
# state file. A disk-level delete of a Nextcloud-tracked file would leave a
# "ghost" in Nextcloud's DB until an `occ files:scan` (needs app DB creds; fragile),
# so we don't delete. Re-dropping a filed doc is harmless — Papra dedups by
# content hash per org. Clear a source folder yourself whenever you like.
set -uo pipefail

DEST="${PAPRA_INBOX_DEST:?PAPRA_INBOX_DEST unset}"          # /mnt/data/papra/ingestion/<orgId>
INBOXES="${PAPRA_INBOXES:?PAPRA_INBOXES unset}"             # colon-separated dirs
STATE_DIR="${PAPRA_INBOX_STATE_DIR:-/var/lib/papra-inbox-watch}"
STATE="$STATE_DIR/seen"
MIN_AGE=10                                                  # secs; skip files still being written

mkdir -p "$STATE_DIR"; touch "$STATE"
mkdir -p "$DEST"
now=$(date +%s)
count=0

process_dir() {
  local inbox="$1"
  [ -d "$inbox" ] || { echo "inbox not present yet: $inbox"; return; }
  while IFS= read -r -d '' f; do
    local mt; mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ $(( now - mt )) -ge "$MIN_AGE" ] || continue         # stability guard
    local sha; sha=$(sha256sum "$f" | cut -d' ' -f1)
    grep -q "^$sha " "$STATE" && continue                  # already filed
    local base; base=$(basename "$f")
    local tmp="$DEST/.incoming-$sha"
    if cp -f "$f" "$tmp" && chown papra:papra "$tmp" && mv -f "$tmp" "$DEST/$base"; then
      chown papra:papra "$DEST/$base"
      echo "$sha $base" >> "$STATE"
      echo "filed: $base ($sha) from $inbox"
      count=$((count+1))
    else
      echo "ERROR filing: $base" >&2
      rm -f "$tmp"
    fi
  done < <(find "$inbox" -maxdepth 1 -type f ! -name '.*' -print0)
}

IFS=':' read -ra dirs <<< "$INBOXES"
for d in "${dirs[@]}"; do
  [ -n "$d" ] && process_dir "$d"
done

echo "done: $count new file(s) queued for Papra ingestion"
