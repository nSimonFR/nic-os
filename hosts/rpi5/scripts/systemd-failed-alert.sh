#!/usr/bin/env bash
# Page on units that STAY failed. A deploy restarts dozens of units and catches
# some mid-stop (ryot/karakeep-web on 2026-11-03 14:14, back by 14:16), and a
# timer oneshot retries on its own; neither is worth a human.
#
# Three sources, because the system manager only knows about the first:
# a failed USER unit is invisible to it (hermes-skill-promote failed
# hourly for eight days unnoticed), and a user manager that is *stopped*
# rather than failed is in neither list (that hid Hermes down for 31h).
#
# Env: TELEGRAM_ALERT (injected by the module), GRACE_SEC.
: "${GRACE_SEC:=1200}" # > the 15-min wakatime-ai-sync timer, so one retry fits

now=$(date +%s)
body=""

# scan <prefix> [systemctl manager args...]
scan() {
  local tag=$1 unit since
  shift
  while read -r unit; do
    [ -n "$unit" ] || continue
    case $unit in
    # `systemd-run` probes agents leave behind; nothing will ever restart them.
    # session-*.scope: a login that exited before boot let logind create its
    # scope (session-c1, 2026-11-11: 5s tailscale-ssh command at boot).
    run-*.service | run-*.scope | session-*.scope)
      echo "reset-failed transient ${tag}${unit}"
      systemctl "$@" reset-failed "$unit" || true
      continue
      ;;
    esac
    since=$(systemctl "$@" show -p StateChangeTimestamp --value --timestamp=unix "$unit")
    since=${since#@}
    ((now - ${since:-0} >= GRACE_SEC)) || continue
    body+="${tag}${unit} failed since $(date -d "@$since" '+%a %H:%M')"$'\n'
  done < <(systemctl "$@" list-units --state=failed --no-legend --plain | awk '{print $1}')
}

scan ""
scan "[user] " --machine=nsimon@.host --user 2>/dev/null
systemctl is-active --quiet user@1001.service ||
  body+="[user] user@1001.service NOT ACTIVE"$'\n'

printf '%s' "$body" | "$TELEGRAM_ALERT" systemd-failed "systemd units failed on rpi5"
