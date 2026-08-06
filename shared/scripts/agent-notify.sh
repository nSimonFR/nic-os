#!/usr/bin/env bash
# agent-notify — hand one agent event to the debounced :8088 aggregator
# (rpi5/scripts/claude-notify-aggregator.py), which owns the bot token and
# decides when a batch becomes one Telegram digest. See shared/notify.nix for
# when this is the wrong seam.
#
# Usage: agent-notify --source SRC [--message M] [--project P] [--immediate]
# Stdin: agent-hook JSON {message?, cwd?} — used for whichever of --message /
#        --project was not passed, so hook callers and script callers share one
#        implementation.
#
# Always exits 0: a missed POST drops one notification rather than blocking the
# agent that called it.
set -u

source_name= message= project= immediate=false have_message=0

while [ $# -gt 0 ]; do
  case $1 in
    -s|--source)  source_name=$2; shift 2 ;;
    -m|--message) message=$2; have_message=1; shift 2 ;;
    -p|--project) project=$2;     shift 2 ;;
    --immediate)  immediate=true; shift ;;
    *)            echo "agent-notify: unknown option $1" >&2; exit 0 ;;
  esac
done

if [ "$have_message" -eq 0 ] || [ -z "$project" ]; then
  payload=$(cat 2>/dev/null)
  [ "$have_message" -eq 0 ] && message=$(jq -r '.message // empty' <<< "$payload" 2>/dev/null)
  [ -z "$project" ] && project=$(basename "$(jq -r '.cwd // ""' <<< "$payload" 2>/dev/null)")
fi

body=$(jq -nc --arg host "$(uname -n)" --arg project "${project:-unknown}" \
  --arg message "$message" --arg source "$source_name" --argjson immediate "$immediate" \
  '{host:$host, project:$project, message:$message, source:$source, immediate:$immediate}')

# rpi5 hits the aggregator on loopback; other hosts fall back to the tailnet
# FQDN. -m 4 bounds the wait so a hook can't hang the agent.
for url in ${AGENT_NOTIFY_URLS:-"http://127.0.0.1:8088/notify https://rpi5.gate-mintaka.ts.net:8088/notify"}; do
  curl -fsS -m 4 -X POST "$url" -H 'Content-Type: application/json' \
    --data-raw "$body" >/dev/null 2>&1 && break
done
exit 0
