#!/usr/bin/env bash
# Every 4h, page if beast is UP with nobody using it. Runs on the rpi5: the whole
# point is to work when the watched box is off, and beast cannot page for itself.
#
# beast-wake arms a self-expiring poweroff on every wake, so normally this never
# fires; it covers the paths that bypass it (bare wakeonlan, failed arming, a
# --cancel never followed up, the power button). The `alert` seam
# (shared/notify.nix) makes it one self-updating message per incident that
# auto-resolves when beast goes off or someone logs in — not a page every 4h.
#
# Env: TELEGRAM_ALERT (injected by the module), BEAST_HOST.
: "${BEAST_HOST:=beast}"

# From the local tailscaled: no auth, no ssh, works with beast off. HostName is
# `BeAsT`, hence the case-insensitive match.
online=$(tailscale status --json 2>/dev/null \
  | jq -r --arg h "$BEAST_HOST" '
      .Peer // {} | to_entries
      | map(select((.value.HostName | ascii_downcase) == ($h | ascii_downcase)
                   or (.value.DNSName | ascii_downcase | startswith(($h | ascii_downcase) + "."))))
      | if length == 0 then "unknown" else (.[0].value.Online | tostring) end' \
  || echo unknown)

body=""
add() { body="${body}$1"$'\n'; }
sect() { awk -v n="$1" 'BEGIN { s = 1 } /^__MARK__$/ { s++; next } s == n' <<< "$remote"; }

case $online in
  false) echo "beast-idle-alert: OK — $BEAST_HOST is off" ;;
  true)
    # One round trip, parsed here. As nsimon because that is the identity
    # tailscale SSH authorises; the service stays root to read the bot token.
    remote=$(runuser -l nsimon -c "ssh -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new $BEAST_HOST '
        loginctl list-sessions --no-legend; echo __MARK__
        uptime -p; echo __MARK__
        systemctl list-units --all --plain --no-legend --type=timer'" 2>/dev/null || true)

    if [ -z "${remote//[[:space:]]/}" ]; then
      # Up but unreachable is still worth paging — "on and nobody can say why"
      # is precisely the state this exists to surface.
      add "• <b>up</b>, but the session check failed (ssh $BEAST_HOST as nsimon)"
    else
      # Column 3 is the user; greetd's own session is on every idle beast.
      users=$(sect 1 | awk '{ print $3 }' | grep -vx 'greeter' | sort -u | tr '\n' ' ' || true)
      if [ -n "${users// /}" ]; then
        echo "beast-idle-alert: OK — $BEAST_HOST is up and in use by ${users% }"
      else
        add "• <b>up</b> $(sect 2 | head -1) with no login session"
        if [ "$(sect 3 | grep -c 'beast-auto-poweroff' || true)" -gt 0 ]; then
          add "• auto-poweroff <b>is</b> armed — it will expire on its own"
        else
          add "• <b>nothing armed</b> — up until powered off by hand"
          add "• <code>ssh $BEAST_HOST 'sudo systemctl poweroff'</code>"
        fi
      fi
    fi
    ;;
  *) echo "beast-idle-alert: could not determine $BEAST_HOST's state (peer not found)" >&2 ;;
esac

if [ -n "$body" ]; then
  echo "beast-idle-alert: ALERT — $BEAST_HOST up with no sessions" >&2
fi
# Empty body clears any open alert; non-empty opens or updates one.
printf '%s' "$body" | "$TELEGRAM_ALERT" "beast-idle-on" "🟡 beast is on with nobody using it"
