#!/usr/bin/env bash
# Claude Code SessionStart hook: label this herdr pane's agent `cc` instead of
# `claude`, so the agent panel carries the kind inline on its first row.
#
# It has to be a hook. Sidebar row templates take a closed set of tokens, a
# literal is rejected outright (`unknown sidebar token 'cc'`), and agent
# manifests have no display-name field — `display_agent` on pane metadata is the
# only source, and it is per-pane runtime state. A herdr restart drops it and
# the row reads `claude` until the next SessionStart.
#
# Beside herdr's own hook, never inside it: that file is herdr-managed and is
# overwritten by every integration update.
set -eu

# Hook input arrives as JSON on stdin. Drain it whether or not we use it, so the
# writer never sees a closed pipe.
cat >/dev/null 2>&1 || true

code="${1:-cc}"

# Not under herdr, or herdr is gone: nothing to label. Never fail the session.
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

# `--source` namespaces the report so it cannot collide with what herdr's own
# integration reports for this pane. No --ttl-ms: the label should outlive the
# turn, and is replaced on the next SessionStart rather than expiring mid-session.
herdr pane report-metadata "$HERDR_PANE_ID" \
  --source nicos:agent-code \
  --display-agent "$code" >/dev/null 2>&1 || true

exit 0
