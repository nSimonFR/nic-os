#!/usr/bin/env bash
# Claude Code SessionStart hook: label this herdr pane's agent `cc` instead of
# `claude`, so the agent panel carries the kind inline on its first row.
#
# `display_agent` is the only source for that code and is per-pane runtime state,
# so it has to be reported from inside the pane. A herdr restart drops it and the
# row reads `claude` again until the next SessionStart.
#
# Beside herdr's own hook, never inside it: that file is overwritten by every
# integration update.
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
