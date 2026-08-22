#!/usr/bin/env bash
# Runs ON beast, fired by the transient timer beast-wake.sh armed. beast may only
# be ON or OFF (suspend is disabled — see hosts/beast/configuration.nix), so a
# wake expires as a real poweroff; if beast turns out to be in use this re-arms
# instead, since losing a rebuild or an ML job to a timer beats the idle draw it
# is preventing. Lives in /run so it always matches the beast-wake that armed it
# and a reboot clears guard and timer together.
export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH
: "${BEAST_POWEROFF_AFTER:=1h}"
busy=()

# Column 3 is the user. greetd's own session is present on every idle beast
# (users.users.greeter), so it never counts.
sessions=$(loginctl list-sessions --no-legend 2>/dev/null \
  | awk '{ print $3 }' | grep -vx 'greeter' | sort -u | tr '\n' ' ' || true)
[ -n "${sessions// /}" ] && busy+=("session(s): ${sessions% }")

if builds=$(pgrep -c -f 'nixos-rebuild|nix build|nix-build' 2>/dev/null) && [ "$builds" -gt 0 ]; then
  busy+=("$builds nix build(s)")
fi

# A compute app holding VRAM means an Immich ML job is running right now; the
# model itself is evicted after 5 min idle, so an idle beast reports nothing.
if gpu=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null) \
   && [ -n "${gpu//[[:space:]]/}" ]; then
  busy+=("$(grep -c . <<< "$gpu") process(es) on the GPU")
fi

if [ ${#busy[@]} -gt 0 ]; then
  printf 'beast-auto-poweroff: in use (%s) — re-arming for %s\n' \
    "$(IFS='; '; echo "${busy[*]}")" "$BEAST_POWEROFF_AFTER"
  # Fresh unit name: this one is still running, so its own name is taken.
  exec systemd-run --collect --on-active="$BEAST_POWEROFF_AFTER" \
    --unit="beast-auto-poweroff-$(date +%s)" \
    --setenv=BEAST_POWEROFF_AFTER="$BEAST_POWEROFF_AFTER" \
    --description='beast auto-poweroff (re-armed: in use)' "${BASH_SOURCE[0]}"
fi

echo 'beast-auto-poweroff: idle — powering off'
exec systemctl poweroff
