#!/usr/bin/env bash
# One-time data migration for the filebrowser → Nextcloud swap.
# Run as root BEFORE `nixos-rebuild switch` on the new flake.
#
# Idempotent — re-running after a successful run is a no-op.
# See ./MIGRATION-nextcloud-datadir.md for context.
set -euo pipefail

ROOT=/mnt/data/cloud
USER_DIR=$ROOT/nsimon
FILES_DIR=$USER_DIR/files
TOP_LEVEL_DIRS=(ADMINISTRATIVE BACKUPS DOCUMENTS)

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root (sudo)." >&2
  exit 1
fi

if [[ ! -d $ROOT ]]; then
  echo "$ROOT does not exist; nothing to migrate." >&2
  exit 1
fi

echo "==> Stopping services that touch $ROOT"
systemctl stop filebrowser.service                       2>/dev/null || true
systemctl stop nextcloud-cron.timer                      2>/dev/null || true
systemctl stop nextcloud-cron.service                    2>/dev/null || true
systemctl stop paperless-scheduler.service               2>/dev/null || true
systemctl stop paperless-task-queue.service              2>/dev/null || true
systemctl stop paperless-consumer.service                2>/dev/null || true
systemctl stop paperless-web.service                     2>/dev/null || true

echo "==> Ensuring nextcloud user/group exist"
id -u nextcloud >/dev/null 2>&1 || { echo "nextcloud user missing — rebuild has not run with the new module yet?" >&2; exit 1; }

echo "==> Creating $FILES_DIR if needed"
mkdir -p "$FILES_DIR"

echo "==> Moving top-level dirs under $FILES_DIR"
for d in "${TOP_LEVEL_DIRS[@]}"; do
  if [[ -e $ROOT/$d && ! -e $FILES_DIR/$d ]]; then
    echo "    mv $ROOT/$d $FILES_DIR/$d"
    mv "$ROOT/$d" "$FILES_DIR/$d"
  elif [[ -e $FILES_DIR/$d ]]; then
    echo "    skip $d (already migrated)"
  else
    echo "    skip $d (no source)"
  fi
done

# Sweep up known macOS metadata cruft at the old root
rm -f "$ROOT/.DS_Store" "$ROOT/._.DS_Store" "$ROOT/._ADMINISTRATIVE" 2>/dev/null || true

echo "==> chown -R nextcloud:nextcloud $USER_DIR"
chown -R nextcloud:nextcloud "$USER_DIR"
chmod 0755 "$USER_DIR" "$FILES_DIR"

# Each top-level dir under files/ stays group-readable for paperless to traverse.
for d in "${TOP_LEVEL_DIRS[@]}"; do
  if [[ -d $FILES_DIR/$d ]]; then
    chmod 0755 "$FILES_DIR/$d"
  fi
done

# Restore paperless ownership on the consume leaf
PAPERLESS_CONSUME=$FILES_DIR/ADMINISTRATIVE/paperless-consume
if [[ -d $PAPERLESS_CONSUME ]]; then
  echo "==> chown -R paperless:paperless $PAPERLESS_CONSUME"
  chown -R paperless:paperless "$PAPERLESS_CONSUME"
  chmod 0755 "$PAPERLESS_CONSUME"
fi

echo "==> chown $ROOT to nextcloud:nextcloud (datadir root)"
chown nextcloud:nextcloud "$ROOT"
chmod 0755 "$ROOT"

# Wipe the old empty Nextcloud datadir so the new install starts fresh on /mnt/data/cloud
if [[ -d /var/lib/nextcloud/data && -z $(ls -A /var/lib/nextcloud/data) ]]; then
  echo "==> Removing empty /var/lib/nextcloud/data"
  rmdir /var/lib/nextcloud/data
elif [[ -d /var/lib/nextcloud/data ]]; then
  echo "==> /var/lib/nextcloud/data is not empty; leaving it alone"
  ls -la /var/lib/nextcloud/data
fi

echo
echo "==> Migration complete."
echo "    Next: sudo nixos-rebuild switch --flake /home/nsimon/nic-os#rpi5 --max-jobs 1 -j 1"
echo "    Then: sudo nextcloud-occ files:scan nsimon"
