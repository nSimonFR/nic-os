#!/usr/bin/env bash
# Open a herdr pane's agent session in `zoe`.
#
# Usage: herdr-zoe          — from a `type = "pane"` keybind: the pane underneath
#        herdr-zoe split    — split the focused pane, run zoe there
#        herdr-zoe <pane>   — draw that pane's session in the current terminal
#
# Upstream's herdr plugin does this and cannot work here: it resolves herdr via
# $HERDR_BIN_PATH, which herdr computes as /opt/homebrew/bin/herdr on macOS with
# no -x check, so on nix it points at nothing.
set -euo pipefail

die() {
  printf '\n  %s\n\n' "$*" >&2
  read -r -p '  press enter to close ' _ || true
  exit 1
}

if [ "${1:-}" = split ]; then
  # A `type = "shell"` keybind is detached: the focused pane is HERDR_ACTIVE_*.
  from="$HERDR_ACTIVE_PANE_ID"
  pane=$(herdr pane split --pane "$from" --direction right \
    --cwd "${HERDR_ACTIVE_PANE_CWD:-$PWD}" --focus | jq -r '.result.pane.pane_id')
  # `exec` so the split closes with zoe.
  herdr pane run "$pane" "exec herdr-zoe $from" >/dev/null
  exit 0
fi

pane=$(herdr pane get "${1:-${HERDR_ACTIVE_PANE_ID:?no pane given and no HERDR_ACTIVE_PANE_ID}}" 2>/dev/null |
  jq '.result.pane // empty' 2>/dev/null || true)

agent=$(printf '%s' "$pane" | jq -r '.agent_session.agent // .agent // empty' 2>/dev/null || true)
kind=$(printf '%s' "$pane" | jq -r '.agent_session.kind // empty' 2>/dev/null || true)
id=$(printf '%s' "$pane" | jq -r '.agent_session.value // empty' 2>/dev/null || true)

case "$agent" in
  claude | codex)
    if [ "$kind" = "id" ] && [ -n "$id" ]; then
      # The agent is live, so open at the live edge; space and the scrubber go back.
      zoe --provider "$agent" --follow "$id" || die "zoe exited with status $?"
      exit 0
    fi
    ;;
esac

# No usable id: fall back to this project's newest session.
zoe || die "zoe found no session for $PWD (status $?)"
