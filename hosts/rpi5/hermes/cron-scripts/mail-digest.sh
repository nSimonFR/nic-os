#!/usr/bin/env bash
# Self-sending, so stdout is dropped. Zero model tokens: classification is Jev's
# and the wording is the script's, so a plan-cap 429 cannot take the digest down.
# TYPESAFE_API_KEY comes inherited from the gateway — see cronScriptsDir in
# hermes.nix — with a read of /run/agenix/agent-env as the fallback.
export TELEGRAM_CHAT_ID=@chatId@
export TELEGRAM_SEND=@tgSend@
export MAIL_GMAIL_ACCOUNTS="personal=hemeraude@gmail.com"
export PROTON_USER="nsimon@protonmail.com"
export MAIL_PROTON_ROLE=personal
export MAIL_PROTON_INDEX=1
exec @bin@/hermes-mail-digest >/dev/null
