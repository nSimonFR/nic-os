#!/usr/bin/env bash
# Idempotently register the Papra organization webhook that drives the Nextcloud
# tag-sync receiver. Papra stores webhooks as DB rows (not config), so this
# reconciles them on every activation — surviving a Papra DB reset and picking up
# a rotated HMAC secret. Runs as root (reads the nextcloud-owned secret + writes
# the papra DB), then restores papra ownership of the DB files.
set -uo pipefail

DB="${PAPRA_DB:?}"
ORG="${PAPRA_ORG:?}"
URL="${PAPRA_WEBHOOK_URL:?}"
SECRET_FILE="${PAPRA_WEBHOOK_SECRET_FILE:?}"

[ -f "$DB" ] || { echo "papra DB not present yet, skipping"; exit 0; }
# Papra migrates its schema on first run; do nothing until the tables exist.
if [ -z "$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='webhooks';")" ]; then
  echo "webhooks table not migrated yet, skipping"
  exit 0
fi

SECRET="$(cat "$SECRET_FILE")"
now=$(( $(date +%s) * 1000 ))
wid="$(sqlite3 "$DB" "SELECT id FROM webhooks WHERE organization_id='$ORG' AND name='nextcloud-tag-sync' LIMIT 1;")"

if [ -n "$wid" ]; then
  sqlite3 "$DB" "UPDATE webhooks SET url='$URL', secret='$SECRET', enabled=1, updated_at=$now WHERE id='$wid';"
  echo "updated webhook $wid"
else
  wid="wh_$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sqlite3 "$DB" "INSERT INTO webhooks(id,created_at,updated_at,name,url,secret,enabled,organization_id) VALUES('$wid',$now,$now,'nextcloud-tag-sync','$URL','$SECRET',1,'$ORG');"
  for ev in document:created document:tag:added document:updated; do
    eid="whe_$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sqlite3 "$DB" "INSERT INTO webhook_events(id,created_at,updated_at,webhook_id,event_name) VALUES('$eid',$now,$now,'$wid','$ev');"
  done
  echo "registered webhook $wid"
fi

# We wrote as root; keep the DB (and any WAL/SHM sidecars) owned by papra.
chown papra:papra "$DB" "$DB-wal" "$DB-shm" 2>/dev/null || true
