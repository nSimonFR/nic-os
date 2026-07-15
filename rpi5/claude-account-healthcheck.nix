# Health probe + proactive alerting for tiny-llm-gate's two Anthropic accounts.
#
# tiny-llm-gate fails over between two OAuth tokens (/run/claude-oauth/token =
# acct1, /run/claude-oauth-2/token = acct2). A dead token used to wedge the
# whole pool (fixed in gate v0.8.1 by failing over on 401), but a dead acct2
# still silently removes all failover headroom — exactly the state that caused
# the outage this guards against. This oneshot probes each token directly
# against api.anthropic.com hourly and pages (self-updating Telegram message)
# when an account is dead/missing or when both tokens are identical (no
# headroom — e.g. the mirror-stopgap, or a failed secondary re-login).
#
# On-demand "test both sessions" is: sudo systemctl start
# anthropic-account-healthcheck  (then journalctl -u it -n 20).
{ config, pkgs, lib, telegramChatId, ... }:
let
  # Same self-updating alerter monitoring.nix uses; a thin wrapper over the
  # shared telegram-alert.sh (send-once / edit-in-place / resolve). Kept local
  # to this module so it stays self-contained.
  telegramAlert = pkgs.writeShellScript "telegram-alert-anthropic" ''
    export TELEGRAM_TOKEN_FILE=${config.age.secrets.telegram-bot-token.path}
    export TELEGRAM_CHAT_ID=${toString telegramChatId}
    export ALERT_STATE_DIR=/var/lib/telegram-alerts
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils ]}''${PATH:+:$PATH}
    exec ${pkgs.bash}/bin/bash ${./telegram-alert.sh} "$@"
  '';

  healthcheck = pkgs.writeShellScript "anthropic-account-healthcheck" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}''${PATH:+:$PATH}

    TOK1=/run/claude-oauth/token
    TOK2=/run/claude-oauth-2/token

    # Probe one token file against the real Anthropic API. Uses an empty JSON
    # body: auth is validated before request-body validation, so a live token
    # returns 400 (invalid_request) while a dead token returns 401/403 — this
    # is a zero-cost probe (no model tokens are ever consumed). Any non-auth
    # status therefore means the credential was accepted.
    #   echoes: "OK <code>" | "DEAD <code>" | "MISSING" | "EMPTY" | "NETERR"
    probe() {
      local f=$1 tok code
      [ -r "$f" ] || { echo "MISSING"; return; }
      tok=$(cat "$f")
      [ -n "$tok" ] || { echo "EMPTY"; return; }
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
        -X POST https://api.anthropic.com/v1/messages \
        -H "content-type: application/json" \
        -H "authorization: Bearer $tok" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -d '{}' 2>/dev/null) || { echo "NETERR"; return; }
      case "$code" in
        401|403) echo "DEAD $code" ;;
        000|"")  echo "NETERR" ;;
        *)       echo "OK $code" ;;
      esac
    }

    S1=$(probe "$TOK1")
    S2=$(probe "$TOK2")

    body=""
    add() { body="''${body}$1"$'\n'; }

    # Page on definitive credential problems (not transient network errors).
    case "$S1" in DEAD*|MISSING|EMPTY) add "• acct1 ($TOK1): $S1" ;; esac
    case "$S2" in DEAD*|MISSING|EMPTY) add "• acct2 ($TOK2): $S2" ;; esac

    # No failover headroom: both slots hold the same token (mirror-stopgap, or
    # a failed secondary login). Sessions still work, but resilience is gone.
    # Plain string compare (cat + test) avoids a diffutils dependency for cmp.
    if [ -r "$TOK1" ] && [ -r "$TOK2" ] && [ "$(cat "$TOK1")" = "$(cat "$TOK2")" ]; then
      add "• no failover headroom: acct1 and acct2 tokens are identical"
    fi

    if [ -n "$body" ]; then
      echo "anthropic-account-healthcheck: ALERT acct1=$S1 acct2=$S2" >&2
    else
      echo "anthropic-account-healthcheck: OK acct1=$S1 acct2=$S2"
    fi

    # Empty body clears any open alert; non-empty opens/updates one.
    printf '%s' "$body" | ${telegramAlert} "anthropic-accounts" "🔴 Anthropic gate account issue"
  '';
in
{
  systemd.services.anthropic-account-healthcheck = {
    description = "Probe both tiny-llm-gate Anthropic accounts and alert on failure";
    # Runs as root: needs to read the 0444-but-root-owned-dir token files and
    # the age-encrypted telegram bot token.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = healthcheck;
    };
  };

  systemd.timers.anthropic-account-healthcheck = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
