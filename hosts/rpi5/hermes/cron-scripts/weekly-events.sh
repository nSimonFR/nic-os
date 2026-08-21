#!/usr/bin/env bash
# Reports only what changed, so a quiet week is silent. No `--send`: stdout is
# the delivery path. `cd` because its SQLite state path is relative.
cd @hermesHome@/workspace/weekly-events || exit 1
exec @python3@ -m weekly_events.app \
  --config sources.json --state data/events.sqlite3 --log-level WARNING
