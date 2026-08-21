#!/usr/bin/env bash
# Self-sending: HTML with a deep link into the day's timeline.
set -euo pipefail

# Hermes scrubs secret-shaped variables before spawning us, so the Dawarich key
# is re-sourced here. Doing it in this shim keeps the Python side env-only, and
# therefore testable off-host.
set -a
# shellcheck source=/dev/null
. /run/agenix/agent-env
set +a

export TELEGRAM_CHAT_ID=@chatId@
export TELEGRAM_SEND=@tgSend@
exec @bin@/hermes-dawarich-daily >/dev/null
