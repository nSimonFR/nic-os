#!/usr/bin/env bash
# Open the focused herdr pane's agent session in `zoe` (the subagent graph).
#
# WHY NOT UPSTREAM'S PLUGIN: furkankly/zoetrope ships a herdr plugin that does
# exactly this, and it cannot work on a non-Homebrew install. Its scripts do
# `herdr="${HERDR_BIN_PATH:-herdr}"`, and herdr COMPUTES that variable as
# /opt/homebrew/bin/herdr on macOS regardless of where herdr actually is —
# handed out with no -x check, so on nix every action died with
# `/opt/homebrew/bin/herdr: No such file or directory`. The `:-` fallback never
# fires because the value is set, just wrong. Not fixed by restarting (the
# server carries no HERDR_* env, so the path is computed, not inherited) and not
# patchable in place (the plugin dir is refetched on reinstall). herdr's own
# integration scripts guard this with `[ -x "$HERDR_BIN_PATH" ]`; zoetrope's do
# not. Upstream bug, worth reporting.
#
# WHY THE FALLBACK: upstream reads the target pane from
# HERDR_PLUGIN_CONTEXT_JSON's `focused_pane_id`, which only exists for a plugin
# invocation — a `popup` keybinding does not get one. `herdr pane current` is
# the nearest equivalent, but a popup may hold focus itself, in which case it
# answers with a pane that has no agent. So: use it when it names an agent pane
# with a session id, and otherwise let `zoe` pick the newest session in this
# project, which is what it does with no arguments. The second path is right
# whenever a project has one live session, and picks the most recent when it
# has several.
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
