#!/usr/bin/env bash
# Open a pane running Claude, in the focused pane's directory.
#
# Usage: herdr-claude-open <down|right|tab|workspace>
#
# Bound to prefix+" / % / shift+c / shift+s in herdr-config.toml. A
# `type = "shell"` keybind is DETACHED, so there is no HERDR_PANE_ID here —
# herdr passes the focused pane as HERDR_ACTIVE_*.
#
# `herdr` is called by name so runtimeInputs wins: HERDR_BIN_PATH is inherited
# from whatever started the pane and can point at a store path that is gone (or,
# observed here, a leftover /opt/homebrew/bin/herdr).
set -euo pipefail

from="$HERDR_ACTIVE_PANE_ID"
cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"

case "${1:-down}" in
  down | right)
    pane=$(herdr pane split --pane "$from" --direction "$1" --cwd "$cwd" --focus |
      jq -r '.result.pane.pane_id')
    ;;
  tab)
    pane=$(herdr tab create --workspace "$HERDR_ACTIVE_WORKSPACE_ID" --cwd "$cwd" --focus |
      jq -r '.result.root_pane.pane_id')
    ;;
  workspace)
    pane=$(herdr workspace create --cwd "$cwd" --label "${cwd##*/}" --focus |
      jq -r '.result.root_pane.pane_id')
    ;;
  *)
    echo "usage: herdr-claude-open <down|right|tab|workspace>" >&2
    exit 1
    ;;
esac

# The calling pane's Claude session, when it has one. With nothing to fork there
# is nothing to ask, so Claude just starts.
session=$(herdr pane get "$from" | jq -r '.result.pane.agent_session.value // empty')

# `pane run`, not `agent start`: both the menu and `claude` have to be resolved
# by the pane's own interactive zsh, where claude() is the shim that adds
# --remote-control and the Aperture proxy (zsh/aliases.zsh). `agent start` would
# wait for readiness, which this gives up — in practice the new shell has its
# prompt well before the split returns.
if [ -n "$session" ]; then
  herdr pane run "$pane" "claude-pane-menu $from $session" >/dev/null
else
  herdr pane run "$pane" claude >/dev/null
fi
