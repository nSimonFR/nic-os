#!/usr/bin/env bash
# Self-sending: a media group, which stdout cannot carry. On "no memories today"
# it prints and exits 0, so the tick goes silent.
set -euo pipefail

# Hermes scrubs secret-shaped variables before spawning us, so the Immich
# credentials are re-sourced here rather than inherited.
set -a
# shellcheck source=/dev/null
. /run/agenix/agent-env
set +a

export HOME=/home/nsimon
exec @python3@ @hermesHome@/skills/immich-memories/scripts/immich-on-this-day.py \
  --send-album --chat-id @chatId@ >/dev/null
