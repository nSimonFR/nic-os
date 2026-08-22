#!/usr/bin/env bash
# Wake beast and arm a self-expiring poweroff on it. Runs from the rpi5 because
# WOL is layer-2 only and this is the only box on beast's LAN.
#
# beast may only be ON or OFF — hosts/beast/configuration.nix disables suspend
# (s2idle freezes PID 1, so the SP5100 watchdog force-resets after 120s) and
# nothing turns it off, so an unguarded wake lasts until a human notices: once
# 2d20h, after a 3-minute nix eval. beast-auto-poweroff.sh re-arms rather than
# powering off a beast that is in use, so a wake you keep using is never yanked.
#
# Usage: beast-wake [--after <systemd span>] [--no-poweroff] [--cancel]
# Env: BEAST_MAC / BEAST_HOST / BEAST_LAN_BROADCAST / BEAST_WAIT_SECS;
# BEAST_AUTOPOWEROFF_SCRIPT is injected by hosts/rpi5/beast-power.nix.

# Link-local id, not a credential — until now it lived only in shell history.
: "${BEAST_MAC:=c8:7f:54:0a:40:ec}"
: "${BEAST_HOST:=beast}"
: "${BEAST_LAN_BROADCAST:=192.168.1.255}"
: "${BEAST_WAIT_SECS:=180}"
after=1h arm=yes cancel=no

while [ $# -gt 0 ]; do
  case $1 in
    --after)       after=${2:?--after needs a systemd time span}; shift 2 ;;
    --no-poweroff) arm=no;     shift ;;
    --cancel)      cancel=yes; shift ;;
    -h|--help)     echo 'beast-wake [--after <span>] [--no-poweroff] [--cancel]'; exit 0 ;;
    *)             echo "beast-wake: unknown argument: $1" >&2; exit 2 ;;
  esac
done

ssh_beast() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$BEAST_HOST" "$@"
}
# Units are beast-auto-poweroff-<epoch> — the guard's re-arm needs a free name.
disarm() { ssh_beast "sudo systemctl stop 'beast-auto-poweroff-*.timer' 2>/dev/null || true"; }

if [ "$cancel" = yes ]; then
  ssh_beast true 2>/dev/null || { echo "beast-wake: $BEAST_HOST unreachable — nothing to disarm" >&2; exit 1; }
  disarm
  echo "beast-wake: disarmed — $BEAST_HOST stays up until powered off by hand"
  exit 0
fi

if ssh_beast true 2>/dev/null; then
  echo "beast-wake: $BEAST_HOST is already up"
else
  # Both forms (some switches drop 255.255.255.255), 3× each: it is fire-and-forget UDP.
  for _ in 1 2 3; do
    wakeonlan "$BEAST_MAC" > /dev/null
    wakeonlan -i "$BEAST_LAN_BROADCAST" "$BEAST_MAC" > /dev/null
  done
  echo "beast-wake: packets sent to $BEAST_MAC, waiting for ssh (~40s typical)"
  deadline=$(( SECONDS + BEAST_WAIT_SECS ))
  until ssh_beast true 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "beast-wake: no ssh after ${BEAST_WAIT_SECS}s — a hard GPU stall needs a physical power-cycle" >&2
      exit 1
    fi
    sleep 5
  done
  echo "beast-wake: $BEAST_HOST up after ${SECONDS}s"
fi

if [ "$arm" = no ]; then
  echo "beast-wake: --no-poweroff — nothing armed; ssh $BEAST_HOST 'sudo systemctl poweroff'"
  exit 0
fi

# Guard and timer both live in /run, so a reboot clears them together and never
# leaves a timer pointing at a path that is gone.
guard=/run/beast-auto-poweroff
unguarded="beast is UP and UNGUARDED: ssh $BEAST_HOST 'sudo systemctl poweroff'"
ssh_beast "sudo tee $guard > /dev/null && sudo chmod 0755 $guard" < "$BEAST_AUTOPOWEROFF_SCRIPT" \
  || { echo "beast-wake: guard install failed — $unguarded" >&2; exit 1; }
disarm
ssh_beast "sudo systemd-run --collect --on-active=$after --unit=beast-auto-poweroff-\$(date +%s) \
    --setenv=BEAST_POWEROFF_AFTER=$after --description='beast auto-poweroff (beast-wake)' $guard" > /dev/null 2>&1 \
  || { echo "beast-wake: FAILED to arm — $unguarded" >&2; exit 1; }
echo "beast-wake: armed — $BEAST_HOST powers off in $after unless in use ('beast-wake --cancel' keeps it up)"
