#!/usr/bin/env bash
# The app lives in the seeded workspace so its SQLite snapshot survives outside
# the store. Reports only what changed, so a quiet week is silent. No `--send`:
# stdout is the delivery path.
set -euo pipefail

cd @hermesHome@/workspace/weekly-events
exec @python3@ -m weekly_events.app \
  --config sources.json --state data/events.sqlite3 --log-level WARNING
