# Health probe + proactive alerting for tiny-llm-gate's Anthropic account(s).
#
# The gate's pool is SINGLE-ACCOUNT since 2026-08-18 (acct2's failover entry is
# commented out in tiny-llm-gate.nix — its token 403s on the raw OAuth
# passthrough). So the only credential that can take the gate down is acct1
# (/run/claude-oauth/token), and that is the only thing this pages on. This
# oneshot probes it directly against api.anthropic.com hourly and alerts via a
# self-updating Telegram message when it is dead/missing.
#
# acct2 (/run/claude-oauth-2/token) is still probed, but only for visibility in
# the journal: the keep-warm sidecar stays enabled so the spare is ready to
# re-enable, and its status is what tells you whether re-enabling would work.
# Its page — and the "both tokens identical / no failover headroom" page, which
# is meaningless with one account — are commented out just below, alongside the
# accounts entry they belong to.
#
# On-demand "test the sessions" is: sudo systemctl start
# anthropic-account-healthcheck  (then journalctl -u it -n 20).
{ config, pkgs, lib, telegramChatId, ... }:
let
  # Same self-updating alerter monitoring.nix uses (send-once / edit-in-place /
  # resolve), from the shared seam in shared/notify.nix.
  telegramAlert = (import ../../../shared/notify.nix { inherit pkgs; }).alert {
    tokenFile = config.age.secrets.telegram-bot-token.path;
    chatId = telegramChatId;
    name = "telegram-alert-anthropic";
  };

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
    # Only acct1 pages: it is the gate's only account, so it is the only one
    # whose death is an outage. acct2's status is still computed above and
    # printed below, just not paged on.
    case "$S1" in DEAD*|MISSING|EMPTY) add "• acct1 ($TOK1): $S1" ;; esac
    # DISABLED 2026-08-18 with acct2's entry in tiny-llm-gate.nix — acct2 IS
    # currently DEAD 403 on this probe, which is precisely why it was dropped
    # from the pool, so leaving this in would re-page an accepted state hourly.
    # case "$S2" in DEAD*|MISSING|EMPTY) add "• acct2 ($TOK2): $S2" ;; esac

    # No failover headroom: both slots hold the same token (mirror-stopgap, or
    # a failed secondary login). Sessions still work, but resilience is gone.
    # Plain string compare (cat + test) avoids a diffutils dependency for cmp.
    #
    # DISABLED 2026-08-18: with a single account in the pool there is no
    # headroom to lose, so this can only ever be a false positive. Re-enable
    # together with acct2 in tiny-llm-gate.nix.
    # if [ -r "$TOK1" ] && [ -r "$TOK2" ] && [ "$(cat "$TOK1")" = "$(cat "$TOK2")" ]; then
    #   add "• no failover headroom: acct1 and acct2 tokens are identical"
    # fi

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
