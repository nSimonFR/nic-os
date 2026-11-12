# shellcheck shell=bash
# Fails (→ systemd-failed-alert → Telegram) when a nightly dump is missing,
# stale, empty or under half the size of the previous one, or when Storj's
# newest snapshot is older than MAX_AGE_H.
# A dump unit that exits 0 having written nothing is invisible otherwise.
# Env: PG_DIR, PG_DBS (space-separated), DUMP_ROOT, MAX_AGE_H, STORJ_REMOTE,
# STORJ_ALERT, RCLONE_CONFIG.

now=$(date +%s)
max=$((MAX_AGE_H * 3600))
problems=()

age_ok() { [ $((now - $(stat -c %Y "$1"))) -le "$max" ]; }

# A dump of a wiped or half-migrated database is fresh and non-empty.
shrunk() { [ -s "$2" ] && [ $(($(stat -c %s "$1") * 2)) -lt "$(stat -c %s "$2")" ]; }

for db in $PG_DBS; do
  f="$PG_DIR/$db.sql"
  if [ ! -s "$f" ]; then
    problems+=("postgres $db: $f missing or empty")
  elif ! age_ok "$f"; then
    problems+=("postgres $db: $f older than ${MAX_AGE_H}h")
  elif shrunk "$f" "$PG_DIR/$db.prev.sql"; then
    problems+=("postgres $db: $f is under half the size of $db.prev.sql")
  fi
done

for dir in "$DUMP_ROOT"/*/; do
  dir=${dir%/}
  [ "$dir" = "$PG_DIR" ] && continue
  # Any depth: Tuwunel's RocksDB backup engine writes only into subdirs.
  newest=$(find "$dir" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
  if [ -z "$newest" ]; then
    problems+=("$dir: no dump")
  elif ! age_ok "$newest"; then
    problems+=("$dir: newest dump older than ${MAX_AGE_H}h")
  fi
  # One dir can hold several kinds of dump (hass-*.db, hass-config-*.tar):
  # compare each kind, named minus its date, with the one before it.
  declare -A prev=()
  while IFS= read -r f; do
    kind=$(basename "$f" | tr -d 0-9)
    case "${prev[$kind]:-}" in
    "") prev[$kind]=$f ;;
    "done") ;;
    *)
      if shrunk "${prev[$kind]}" "$f"; then
        problems+=("${prev[$kind]}: under half the size of $f")
      fi
      prev[$kind]="done"
      ;;
    esac
  done < <(find "$dir" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
  unset prev
  while IFS= read -r empty; do
    problems+=("$empty: empty")
  done < <(find "$dir" -maxdepth 1 -type f -empty -mmin -$((MAX_AGE_H * 60)))
done

# Listing is free and works while Storj refuses downloads; restic itself
# cannot even read its key then.
snap=$(rclone lsjson --files-only "$STORJ_REMOTE/snapshots" | jq -r 'map(.ModTime) | max // empty')
if [ -z "$snap" ]; then
  problems+=("restic: no snapshot")
elif [ $((now - $(date -d "$snap" +%s))) -gt "$max" ]; then
  problems+=("restic: newest snapshot $snap older than ${MAX_AGE_H}h")
fi

# A refused download surfaces in restic as "key does not exist" and in check
# as "repository is damaged". Name it; an empty body clears the alert.
blocked=""
if ! err=$(rclone cat "$STORJ_REMOTE/config" 2>&1 >/dev/null) &&
  grep -q "bandwidth limit exceeded" <<<"$err"; then
  blocked="Storj refuses downloads: the project's download limit is reached. Backups and checks fail until it resets on the 1st or the limit is raised (Storj console → project → Download)."
  problems+=("storj: download limit reached")
fi
printf '%s' "$blocked" | "$STORJ_ALERT" storj-download-limit "Storj download limit reached"

if [ ${#problems[@]} -gt 0 ]; then
  printf '%s\n' "${problems[@]}" >&2
  exit 1
fi
echo "backup-freshness: all dumps and the Storj snapshot are under ${MAX_AGE_H}h"
