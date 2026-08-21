#!/usr/bin/env bash
# Prints its report (including an honest "none this week"), so stdout is the
# message. No `cd`: it resolves its config and seen-set from its own __file__.
set -euo pipefail

exec @python3@ @hermesHome@/workspace/job-alerts/job_alert.py
