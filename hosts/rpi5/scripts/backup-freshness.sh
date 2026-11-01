# Fails (→ systemd-failed-alert → Telegram) when a nightly dump is missing,
# stale or empty, or when Storj's newest snapshot is older than MAX_AGE_H.
# A dump unit that exits 0 having written nothing is invisible otherwise.
# Env: PG_DIR, PG_DBS (space-separated), DUMP_ROOT, MAX_AGE_H.

now=$(date +%s)
max=$((MAX_AGE_H * 3600))
problems=()

age_ok() { [ $((now - $(stat -c %Y "$1"))) -le "$max" ]; }

for db in $PG_DBS; do
  f="$PG_DIR/$db.sql"
  if [ ! -s "$f" ]; then
    problems+=("postgres $db: $f missing or empty")
  elif ! age_ok "$f"; then
    problems+=("postgres $db: $f older than ${MAX_AGE_H}h")
  fi
done

for dir in "$DUMP_ROOT"/*/; do
  dir=${dir%/}
  [ "$dir" = "$PG_DIR" ] && continue
  newest=$(find "$dir" -maxdepth 1 -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
  if [ -z "$newest" ]; then
    problems+=("$dir: no dump")
  elif ! age_ok "$newest"; then
    problems+=("$dir: newest dump older than ${MAX_AGE_H}h")
  fi
  while IFS= read -r empty; do
    problems+=("$empty: empty")
  done < <(find "$dir" -maxdepth 1 -type f -empty -mmin -$((MAX_AGE_H * 60)))
done

snap=$(restic snapshots --no-lock --latest 1 --json | jq -r '.[-1].time // empty')
if [ -z "$snap" ]; then
  problems+=("restic: no snapshot")
elif [ $((now - $(date -d "$snap" +%s))) -gt "$max" ]; then
  problems+=("restic: newest snapshot $snap older than ${MAX_AGE_H}h")
fi

if [ ${#problems[@]} -gt 0 ]; then
  printf '%s\n' "${problems[@]}" >&2
  exit 1
fi
echo "backup-freshness: all dumps and the Storj snapshot are under ${MAX_AGE_H}h"
