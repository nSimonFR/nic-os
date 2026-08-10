#!/usr/bin/env bash
# Report backup artifacts that are missing or stale.
#
# Writes an alert BODY to stdout — empty means everything is fresh, which is what
# telegram-alert.sh reads as "resolved". Nothing here sends anything itself.
#
#   backup-freshness.sh <max_age_hours> <label>=<glob> [<label>=<glob> …]
#
# Why this exists: Immich's database backup failed every night for 34 days and
# nobody noticed. Two separate things hid it — the job's own status counter
# reported zero failures throughout, and the failure was inside an application
# job rather than a systemd unit, so `systemd-failed-alert` could not see it
# either.
#
# So this watches the ARTEFACT, not the job. A dump that is missing or stale is a
# broken backup regardless of which layer broke, whether the unit failed, was
# never scheduled, ran but wrote nothing, or wrote somewhere else.
set -uo pipefail

max_age_hours=${1:?usage: backup-freshness.sh <max_age_hours> <label>=<glob>...}
shift

now=$(date +%s)
max_age_sec=$(( max_age_hours * 3600 ))
problems=()

for spec in "$@"; do
  label=${spec%%=*}
  glob=${spec#*=}

  # Newest match. `ls -t` on an unquoted glob is deliberate: the caller passes a
  # pattern, and a pattern that matches nothing must be reported, not expanded to
  # itself and then stat'd.
  newest=$(find "$(dirname "$glob")" -maxdepth 1 -type f -name "$(basename "$glob")" \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)

  if [ -z "$newest" ]; then
    problems+=("<b>$label</b> — no backup found (<code>$glob</code>)")
    continue
  fi

  mtime=${newest%% *}
  path=${newest#* }
  age_sec=$(( now - ${mtime%.*} ))

  if [ "$age_sec" -gt "$max_age_sec" ]; then
    age_h=$(( age_sec / 3600 ))
    problems+=("<b>$label</b> — ${age_h}h old, expected under ${max_age_hours}h (<code>$(basename "$path")</code>)")
  fi
done

# Empty output = the condition has cleared. telegram-alert.sh edits the existing
# message to "resolved" rather than sending anything new.
if [ ${#problems[@]} -eq 0 ]; then
  exit 0
fi

printf '%s\n' "${problems[@]}"
