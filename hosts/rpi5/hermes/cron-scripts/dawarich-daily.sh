#!/usr/bin/env bash
# Self-sending: HTML with a deep link into the day's timeline.
#
# DAWARICH_API_KEY is inherited, not re-sourced here: hermes-exec sources
# /run/agenix/agent-env into the gateway, and the cron child's scrub only strips
# registry-known provider keys (verified against build_subprocess_env —
# GEMINI_API_KEY is stripped, DAWARICH_API_KEY survives).
set -euo pipefail

export TELEGRAM_CHAT_ID=@chatId@
export TELEGRAM_SEND=@tgSend@
exec @bin@/hermes-dawarich-daily >/dev/null
