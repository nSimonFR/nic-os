#!/usr/bin/env bash
# Mirror a Claude session name (/rename) onto the herdr workspace label, until
# that workspace is renamed by hand. Spawned in the background by
# claude-statusline.sh whenever the session name changes.
#
# The label last written here is kept as the workspace's `auto_label` token; a
# label that no longer matches it was set by hand, and is left alone for good.
# With no token (new workspace, or a herdr restart dropped runtime metadata),
# only herdr's stock label — the pane cwd's basename — counts as ours.
#
# Usage: herdr-title-sync <session-name>
set -euo pipefail

name="${1:-}"
[ -n "$name" ] || exit 0
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0

# Resolved from the pane, not $HERDR_WORKSPACE_ID: a moved pane keeps the stale
# env of the workspace it started in.
pane=$(herdr pane get "$HERDR_PANE_ID") || exit 0
ws=$(jq -r '.result.pane.workspace_id // empty' <<<"$pane")
cwd=$(jq -r '.result.pane.cwd // empty' <<<"$pane")
[ -n "$ws" ] || exit 0

info=$(herdr workspace get "$ws") || exit 0
label=$(jq -r '.result.workspace.label // ""' <<<"$info")
auto=$(jq -r '.result.workspace.tokens.auto_label // ""' <<<"$info")

if [ -n "$auto" ]; then
  [ "$label" = "$auto" ] || exit 0
else
  [ "$label" = "${cwd##*/}" ] || exit 0
fi

herdr workspace rename "$ws" "$name" >/dev/null
herdr workspace report-metadata "$ws" --source nicos:title-sync \
  --token "auto_label=$name" >/dev/null
