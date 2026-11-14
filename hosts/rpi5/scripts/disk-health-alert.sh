#!/usr/bin/env bash
# Page on a failing disk before and after it costs us a filesystem.
# On 2026-11-13 /mnt/data went emergency_ro while /proc/mounts still said
# `rw,…,emergency_ro`, and SMART stayed "PASSED" with 400 pending sectors.
#
# Env: TELEGRAM_ALERT (injected by the module), SMART_DEVICES (dev:type,…).
body=""

ro=$(awk '$3 ~ /^(ext4|xfs|btrfs)$/ && $2 !~ /^\/nix\/store|^\/var\/lib\/agent-db\// \
          && $4 ~ /(^|,)(ro|emergency_ro)(,|$)/ { print $1, $2 }' /proc/mounts)
[ -n "$ro" ] && body+="read-only: $ro"$'\n'

# Kept in the superblock until fsck clears it.
for d in /sys/fs/ext4/*/; do
  [ -f "$d/errors_count" ] || continue
  n=$(<"$d/errors_count")
  [ "$n" -gt 0 ] || continue
  body+="ext4 $(basename "$d"): $n error(s), last in $(<"$d/last_error_func") at $(date -d @"$(<"$d/last_error_time")" '+%F %T')"$'\n'
done

for spec in ${SMART_DEVICES//,/ }; do
  dev=${spec%%:*}
  body+=$(smartctl -j -A -d "${spec#*:}" "$dev" | jq -r --arg dev "$dev" '
    .ata_smart_attributes.table[]? | select(.id == 5 or .id == 197 or .id == 198)
    | select(.raw.value > 0) | "SMART \($dev): \(.name)=\(.raw.value)\n"')
done

[ -n "$body" ] && body="<code>${body%$'\n'}</code>"
printf '%s' "$body" | "$TELEGRAM_ALERT" disk-health "Disk failing on rpi5"
