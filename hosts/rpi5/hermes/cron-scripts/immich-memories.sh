#!/usr/bin/env bash
# Self-sending (a media group, which stdout cannot carry), so stdout is dropped.
# "No memories today" prints and exits 0, so the tick goes silent.
exec @python3@ @hermesHome@/skills/immich-memories/scripts/immich-on-this-day.py \
  --send-album --chat-id @chatId@ >/dev/null
