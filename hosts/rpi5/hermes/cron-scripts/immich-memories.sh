#!/usr/bin/env bash
# Self-sending: a media group, which stdout cannot carry. On "no memories today"
# it prints and exits 0, so the tick goes silent.
#
# No agent-env re-source: this script reads IMMICH_API_KEY_FILE and
# TELEGRAM_BOT_TOKEN_FILE, and agent-env carries neither (nor any IMMICH_*), so
# sourcing it here supplied nothing. HOME is already /home/nsimon — Hermes'
# subprocess HOME contract sets it.
set -euo pipefail

exec @python3@ @hermesHome@/skills/immich-memories/scripts/immich-on-this-day.py \
  --send-album --chat-id @chatId@ >/dev/null
