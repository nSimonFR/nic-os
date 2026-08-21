#!/usr/bin/env bash
# Self-sending (HTML, deep link), so stdout is dropped. DAWARICH_API_KEY comes
# inherited from the gateway — see cronScriptsDir in hermes.nix.
export TELEGRAM_CHAT_ID=@chatId@
export TELEGRAM_SEND=@tgSend@
exec @bin@/hermes-dawarich-daily >/dev/null
