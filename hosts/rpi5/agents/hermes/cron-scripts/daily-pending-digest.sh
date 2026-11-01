#!/usr/bin/env bash
# Self-sending, so stdout is a delivery receipt rather than the report: dropped.
exec @bash@ @hermesHome@/workspace/daily-pending-digest.sh >/dev/null
