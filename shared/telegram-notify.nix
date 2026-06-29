# Shared agent-notification hook used by both Claude Code (settings.json
# `Notification` hook) and pi-coding-agent (`agent_end` extension shell-out).
#
# Reads JSON `{message?, cwd?}` on stdin and best-effort POSTs the event to the
# central debounced aggregator on rpi5 (see rpi5/claude-notify-aggregator.{py,nix}),
# which pools events from every machine + agent into one stream and sends a single
# Telegram digest after a quiet period. This hook holds no state and never talks
# to Telegram directly — it just forwards and exits 0, so a missed POST (rpi5
# down / tailnet hiccup) silently drops one notification rather than spamming.
{
  pkgs,
}:
{
  name,
  source,
}:
pkgs.writeShellScript "${name}-telegram-notify" ''
  PAYLOAD=$(cat)
  MESSAGE=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.message // empty')
  CWD=$(echo "$PAYLOAD" | ${pkgs.jq}/bin/jq -r '.cwd // ""')
  PROJECT=$(${pkgs.coreutils}/bin/basename "''${CWD:-unknown}")
  HOST=$(${pkgs.coreutils}/bin/uname -n)

  BODY=$(${pkgs.jq}/bin/jq -nc \
    --arg host "$HOST" \
    --arg project "$PROJECT" \
    --arg message "$MESSAGE" \
    --arg source "${source}" \
    '{host:$host, project:$project, message:$message, source:$source}')

  # rpi5 hits the aggregator on loopback; other hosts fall back to the tailnet
  # FQDN. -m 4 bounds the wait so the hook can't hang the agent.
  for url in "http://127.0.0.1:8088/notify" "https://rpi5.gate-mintaka.ts.net:8088/notify"; do
    if ${pkgs.curl}/bin/curl -fsS -m 4 -X POST "$url" \
         -H 'Content-Type: application/json' \
         --data-raw "$BODY" >/dev/null 2>&1; then
      break
    fi
  done
  exit 0
''
