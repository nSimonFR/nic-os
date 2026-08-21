#!/usr/bin/env bash
# Self-sending: its stdout is a delivery receipt, not a report, so it is dropped.
set -euo pipefail

exec @bash@ @hermesHome@/workspace/daily-pending-digest.sh >/dev/null
