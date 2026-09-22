#!/usr/bin/env bash
# Open the focused herdr pane's agent session in `zoe`.
#
# Upstream's herdr plugin does this and cannot work here: it resolves herdr via
# $HERDR_BIN_PATH, which herdr computes as /opt/homebrew/bin/herdr on macOS with
# no -x check, so on nix it points at nothing.
#
# `herdr pane current` replaces the plugin's `focused_pane_id`, which only exists
# for plugin invocations. It can answer with the popup's own pane, hence the
# fallback to zoe's no-argument mode (newest session in this project).
set -euo pipefail

die() {
  printf '\n  %s\n\n' "$*" >&2
  read -r -p '  press enter to close ' _ || true
  exit 1
}

pane=$(herdr pane current 2>/dev/null | jq '.result.pane // empty' 2>/dev/null || true)

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
