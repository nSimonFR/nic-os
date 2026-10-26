# Usage: agent-db-snapshot <hass|memos|gramps>
# Copies a service's SQLite DB, consistently (online backup API), into
# /var/lib/agent-db/<name>.db, readable by group users. The live files stay in
# the service's private dir; agents query the copy.
out=/var/lib/agent-db

snap() {
  local src=$1 dst=$out/$2.db
  sqlite3 "file:$src?mode=ro" ".backup '$dst.tmp'"
  # A WAL copy can't be opened by a reader that can't write next to it.
  sqlite3 "$dst.tmp" "PRAGMA journal_mode=DELETE;" >/dev/null
  chown root:users "$dst.tmp"
  chmod 0440 "$dst.tmp"
  mv -f "$dst.tmp" "$dst"
  echo "$dst"
}

case "${1:-}" in
  hass) snap /var/lib/hass/home-assistant_v2.db hass ;;
  memos) snap /var/lib/memos/memos_prod.db memos ;;
  gramps)
    for db in /var/lib/gramps-web/data/grampsdb/*/sqlite.db; do
      snap "$db" "gramps-$(basename "$(dirname "$db")")"
    done
    ;;
  *)
    echo "agent-db-snapshot: unknown DB '${1:-}' (hass, memos, gramps)" >&2
    exit 2
    ;;
esac
