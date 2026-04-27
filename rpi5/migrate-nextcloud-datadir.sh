#!/usr/bin/env bash
# One-time data migration for the filebrowser → Nextcloud datadir swap.
# Run as root BEFORE `nixos-rebuild switch` on the new flake.
#
# Idempotent — re-running after a successful run is a no-op.
# See ./MIGRATION-nextcloud-datadir.md for context.
set -euo pipefail

OLD_DATADIR=/var/lib/nextcloud/data
NEW_DATADIR=/mnt/data/cloud
USER_DIR=$NEW_DATADIR/nsimon
FILES_DIR=$USER_DIR/files
TOP_LEVEL_DIRS=(ADMINISTRATIVE BACKUPS DOCUMENTS PHOTOS)
EXTRA_FILES=(mitmproxy-ca.pem)

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root (sudo)." >&2
  exit 1
fi

if [[ ! -d $NEW_DATADIR ]]; then
  echo "$NEW_DATADIR does not exist; nothing to migrate." >&2
  exit 1
fi

echo "==> Stopping services that touch the datadir or filebrowser"
for svc in filebrowser.service \
           nextcloud-cron.timer  nextcloud-cron.service \
           nextcloud-disable-defaults.service \
           paperless-scheduler.service \
           paperless-task-queue.service \
           paperless-consumer.service \
           paperless-web.service \
           phpfpm-nextcloud.service; do
  systemctl stop "$svc" 2>/dev/null || true
done

if ! id -u nextcloud >/dev/null 2>&1; then
  echo "nextcloud user missing — rebuild #200 has not run? Aborting." >&2
  exit 1
fi

echo "==> Phase 1: move Nextcloud internals from $OLD_DATADIR to $NEW_DATADIR"
# Markers (.htaccess, .ncdata, index.html), appdata_*, and the existing user
# scaffold (nsimon/{cache,files}). Without these Nextcloud refuses to start
# at the new datadir — .ncdata is the v33 datadir marker.
if [[ -d $OLD_DATADIR ]]; then
  shopt -s dotglob nullglob
  for src in "$OLD_DATADIR"/*; do
    name=$(basename "$src")
    dst=$NEW_DATADIR/$name
    if [[ -e $dst ]]; then
      echo "    skip $name (already at destination)"
      continue
    fi
    echo "    mv $src → $dst"
    mv "$src" "$dst"
  done
  shopt -u dotglob nullglob
fi

echo "==> Phase 2: move existing user files into $FILES_DIR"
mkdir -p "$FILES_DIR"
for d in "${TOP_LEVEL_DIRS[@]}"; do
  if [[ -e $NEW_DATADIR/$d && ! -e $FILES_DIR/$d ]]; then
    echo "    mv $NEW_DATADIR/$d → $FILES_DIR/$d"
    mv "$NEW_DATADIR/$d" "$FILES_DIR/$d"
  elif [[ -e $FILES_DIR/$d ]]; then
    echo "    skip $d (already in files/)"
  fi
done
for f in "${EXTRA_FILES[@]}"; do
  if [[ -e $NEW_DATADIR/$f && ! -e $FILES_DIR/$f ]]; then
    mv "$NEW_DATADIR/$f" "$FILES_DIR/$f"
  fi
done

echo "==> Phase 3: clean up legacy paperless-consume + macOS cruft"
# The old paperless consume folder under ADMINISTRATIVE is now obsolete (the
# new Nix config points paperless at /mnt/data/cloud/nsimon/files/PAPERLESS).
# Only delete it if it's empty so we don't lose unprocessed documents.
old_consume=$FILES_DIR/ADMINISTRATIVE/paperless-consume
if [[ -d $old_consume ]]; then
  if [[ -z $(ls -A "$old_consume") ]]; then
    echo "    rmdir $old_consume (empty)"
    rmdir "$old_consume"
  else
    echo "    WARNING: $old_consume is not empty — leaving in place. Move contents to PAPERLESS/ manually."
    ls -la "$old_consume"
  fi
fi

# Drop macOS cruft at the new datadir root (used to be filebrowser's root).
for cruft in .DS_Store ._.DS_Store ._ADMINISTRATIVE; do
  rm -f "$NEW_DATADIR/$cruft" 2>/dev/null || true
  rm -f "$FILES_DIR/$cruft"   2>/dev/null || true
done

echo "==> Phase 4: create empty PAPERLESS/ drop-zone"
mkdir -p "$FILES_DIR/PAPERLESS"

echo "==> Phase 5: ownership"
# Whole tree → nextcloud:nextcloud
chown -R nextcloud:nextcloud "$NEW_DATADIR"
chmod 0750 "$NEW_DATADIR"

# Override: PAPERLESS leaf → paperless:paperless (so the consumer can write/delete)
chown -R paperless:paperless "$FILES_DIR/PAPERLESS"
chmod 0755 "$FILES_DIR/PAPERLESS"

# Override: parent dirs need world-traversable so paperless reaches PAPERLESS
chmod 0755 "$NEW_DATADIR" "$USER_DIR" "$FILES_DIR"

echo "==> Phase 6: clean up old datadir if empty"
if [[ -d $OLD_DATADIR && -z $(ls -A "$OLD_DATADIR") ]]; then
  echo "    rmdir $OLD_DATADIR"
  rmdir "$OLD_DATADIR"
elif [[ -d $OLD_DATADIR ]]; then
  echo "    WARNING: $OLD_DATADIR not empty:"
  ls -la "$OLD_DATADIR"
fi

echo
echo "==> Migration complete."
echo "    Layout under $NEW_DATADIR:"
ls -la "$NEW_DATADIR"
echo
echo "    Layout under $FILES_DIR:"
ls -la "$FILES_DIR"
echo
echo "    Next:"
echo "      sudo nixos-rebuild switch --flake /home/nsimon/nic-os#rpi5 --max-jobs 1 -j 1"
echo "      sudo nextcloud-occ files:scan nsimon"
