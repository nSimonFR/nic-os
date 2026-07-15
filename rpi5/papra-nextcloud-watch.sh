#!/usr/bin/env bash
# Feed files dropped into a Nextcloud "Papra Inbox" folder into Papra's ingestion
# drop-zone. Runs on a timer (polling) as root so it can read Nextcloud-owned
# files and write the papra-owned ingestion dir.
#
# Design choice: originals are LEFT IN PLACE and deduped by content hash in a
# state file. We deliberately do NOT delete them from disk — a disk-level delete
# would leave a "ghost" entry in Nextcloud's DB until an `occ files:scan` (which
# needs the app's DB creds staged; fragile). So the inbox doubles as a record of
# what was filed; clear it yourself in Nextcloud whenever you like (that path
# updates Nextcloud's DB correctly). Re-dropping a filed doc is harmless — Papra
# dedups by content hash per org.
set -uo pipefail

INBOX="${PAPRA_NC_INBOX:?PAPRA_NC_INBOX unset}"
DEST="${PAPRA_NC_DEST:?PAPRA_NC_DEST unset}"          # /mnt/data/papra/ingestion/<orgId>
STATE_DIR="${PAPRA_NC_STATE_DIR:-/var/lib/papra-nextcloud-watch}"
STATE="$STATE_DIR/seen"
MIN_AGE=10                                            # secs; skip files still being written

mkdir -p "$STATE_DIR"; touch "$STATE"
# Folder is user-created in Nextcloud; nothing to do until it exists.
[ -d "$INBOX" ] || { echo "inbox not present yet: $INBOX"; exit 0; }
mkdir -p "$DEST"

now=$(date +%s)
count=0
while IFS= read -r -d '' f; do
  mt=$(stat -c %Y "$f" 2>/dev/null) || continue
  [ $(( now - mt )) -ge "$MIN_AGE" ] || continue      # stability guard
  sha=$(sha256sum "$f" | cut -d' ' -f1)
  grep -q "^$sha " "$STATE" && continue               # already filed
  base=$(basename "$f")
  tmp="$DEST/.incoming-$sha"
  if cp -f "$f" "$tmp" && chown papra:papra "$tmp" && mv -f "$tmp" "$DEST/$base"; then
    chown papra:papra "$DEST/$base"
    echo "$sha $base" >> "$STATE"
    echo "filed: $base ($sha)"
    count=$((count+1))
  else
    echo "ERROR filing: $base" >&2
    rm -f "$tmp"
  fi
done < <(find "$INBOX" -maxdepth 1 -type f ! -name '.*' -print0)

echo "done: $count new file(s) queued for Papra ingestion"
