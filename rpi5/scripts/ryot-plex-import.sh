#!/usr/bin/env bash
# Nightly Plex → Ryot watch-history sync (no Plex Pass required).
#
# Ryot v10 has NO working pull integration for Plex watch progress (the yank only
# mirrors libraries; the sink webhook needs Plex Pass, which nSimon lacks). The
# only no-Plex-Pass path is to re-run Ryot's one-time Plex importer on a schedule.
# But that importer is NOT idempotent — the `seen` table has no unique constraint,
# so each re-run duplicates every watch. So: import both shared servers, wait for
# the background jobs to finish, then delete the duplicate `seen` rows (keeping one
# per unique watch event; genuine rewatches differ by finished_on and are kept).
#
# Env (from EnvironmentFile — /run/agenix/ryot-env + /run/agenix/ryot-import-env):
#   DATABASE_URL          postgresql://ryot:…@127.0.0.1:5432/ryot   (from ryot-env)
#   RYOT_LOGIN_USER       Ryot username (admin)
#   RYOT_LOGIN_PASSWORD   Ryot password
#   PLEX_IMPORT_SERVERS   comma-separated  <apiUrl>|<token>  entries (one per server)
# Reaches the backend through the proxy at 127.0.0.1:13350/ryot/backend/graphql.
set -euo pipefail

GQL="http://127.0.0.1:13350/ryot/backend/graphql"
PSQL=(psql "$DATABASE_URL" -tAc)
TIMEOUT_SECS=1800   # max wait for both imports to finish
POLL_SECS=20

log() { echo "[ryot-plex-import] $*"; }

# 1) Authenticate → apiKey (Ryot API needs a user session; admin token can't import).
login_body=$(jq -n --arg u "$RYOT_LOGIN_USER" --arg p "$RYOT_LOGIN_PASSWORD" \
  '{query:"mutation($i:AuthUserInput!){loginUser(input:$i){__typename ... on ApiKeyResponse{apiKey} ... on LoginError{error}}}",variables:{i:{password:{username:$u,password:$p}}}}')
login_resp=$(curl -fsS "$GQL" -H 'Content-Type: application/json' -d "$login_body")
KEY=$(jq -r '.data.loginUser.apiKey // empty' <<<"$login_resp")
if [[ -z "$KEY" ]]; then
  log "LOGIN FAILED: $(jq -c '.data.loginUser // .errors' <<<"$login_resp" 2>/dev/null || echo "$login_resp")"
  exit 1
fi
log "authenticated (apiKey len=${#KEY})"

# 2) Baseline: how many import reports have already finished.
baseline=$("${PSQL[@]}" "SELECT count(*) FILTER (WHERE was_success IS NOT NULL) FROM import_report;")
log "baseline finished import_reports=$baseline"

# 3) Deploy one import per Plex server.
n=0
IFS=',' read -ra servers <<<"$PLEX_IMPORT_SERVERS"
for entry in "${servers[@]}"; do
  url="${entry%%|*}"; tok="${entry##*|}"
  [[ -z "$url" || -z "$tok" || "$url" == "$entry" ]] && { log "skipping malformed server entry"; continue; }
  body=$(jq -n --arg url "$url" --arg tok "$tok" \
    '{query:"mutation($i:DeployImportJobInput!){deployImportJob(input:$i)}",variables:{i:{source:"PLEX",urlAndKey:{apiUrl:$url,apiKey:$tok}}}}')
  resp=$(curl -fsS "$GQL" -H 'Content-Type: application/json' -H "Authorization: Bearer $KEY" -d "$body")
  if [[ "$(jq -r '.data.deployImportJob // false' <<<"$resp")" == "true" ]]; then
    n=$((n+1)); log "deployed import for ${url##*//}"
  else
    log "deploy FAILED for ${url##*//}: $resp"
  fi
done
[[ "$n" -eq 0 ]] && { log "no imports deployed; aborting"; exit 1; }

# 4) Wait for all N imports to finish (report count reaches baseline+N), or timeout.
target=$((baseline + n)); waited=0
while :; do
  fin=$("${PSQL[@]}" "SELECT count(*) FILTER (WHERE was_success IS NOT NULL) FROM import_report;")
  [[ "$fin" -ge "$target" ]] && { log "all $n imports finished"; break; }
  if [[ "$waited" -ge "$TIMEOUT_SECS" ]]; then
    log "WARN: only $((fin-baseline))/$n imports finished after ${TIMEOUT_SECS}s; deduping anyway"
    break
  fi
  sleep "$POLL_SECS"; waited=$((waited+POLL_SECS))
done
# Small settle margin for the final seen writes to commit.
sleep 10

# 5) Dedup: keep the earliest row per (user, metadata, progress, finished_on).
before=$("${PSQL[@]}" "SELECT count(*) FROM seen;")
psql "$DATABASE_URL" -q -c "
WITH d AS (
  SELECT id, row_number() OVER (
    PARTITION BY user_id, metadata_id, progress, finished_on ORDER BY id
  ) AS rn FROM seen
)
DELETE FROM seen WHERE id IN (SELECT id FROM d WHERE rn > 1);"
after=$("${PSQL[@]}" "SELECT count(*) FROM seen;")
log "dedup: seen $before → $after (removed $((before-after)) duplicates)"

# 6) Prune old import reports so they don't accumulate.
psql "$DATABASE_URL" -q -c "DELETE FROM import_report WHERE started_on < now() - interval '14 days';" || true

log "done."
