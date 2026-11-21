#!/usr/bin/env bash
# Cut bad blocks out of the DATA_HDD filesystem (one-off, root, ~10 min of downtime).
#
#   hdd-badblock-cutout.sh scan   [LIST]   read-only full scan -> LIST (hours, no downtime)
#   hdd-badblock-cutout.sh report LIST     map LIST to files / free space (read-only)
#   hdd-badblock-cutout.sh holders         units `cut` would stop (read-only)
#   hdd-badblock-cutout.sh cut    LIST     stop users, unmount, e2fsck -l LIST, remount
#
# LIST is `badblocks -b 4096` output. `cut` refuses while a bad block still
# belongs to a file: delete those files first (via Immich for /immich/library),
# or set ALLOW_USED=1 to let e2fsck clone them (the bad block's data is lost).
# Run it from a shell that is not a child of a stopped service (ssh or tmux).
set -euo pipefail

DEV=/dev/disk/by-label/DATA_HDD
MNT=/mnt/data
# Never stopped: the tailnet, ssh and the agent sessions (umount reports them if busy).
KEEP='^(tailscaled|sshd|t3code|claude-remote-control|herdr|systemd-.*|dbus-broker|serial-getty@.*|init)\.(service|scope)$'

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cmd=${1:?usage: $0 scan|report|cut [LIST]}
list=${2:-/var/tmp/datahdd-bad.txt}

bs=$(tune2fs -l "$DEV" | awk -F: '/^Block size/ {gsub(/ /,"",$2); print $2}')
[ "$bs" = 4096 ] || { echo "fs block size is $bs, lists must be badblocks -b $bs" >&2; exit 1; }

scan() {
  ionice -c3 badblocks -b "$bs" -c 64 -s -v -o "$list" "$DEV"
  echo "bad blocks: $(wc -l < "$list") -> $list"
}

# Print "block<TAB>inode-or-free<TAB>path" per bad block.
report() {
  [ -s "$list" ] || { echo "$list is empty: nothing to cut"; return 0; }
  used=0
  while read -r blk; do
    ino=$(debugfs -R "icheck $blk" "$DEV" 2>/dev/null | awk -v b="$blk" '$1 == b {print $2}')
    if [ -z "$ino" ] || [ "$ino" = "<block" ]; then
      printf '%s\tfree\t-\n' "$blk"
    else
      used=1
      printf '%s\t%s\t%s\n' "$blk" "$ino" "$(debugfs -R "ncheck $ino" "$DEV" 2>/dev/null | awk 'NR==2 {print $2}')"
    fi
  done < "$list"
  return $used
}

sda_mounts() { awk '/ ext4 \/dev\/sda1 / {print $5}' "$1" 2>/dev/null | sort; }

# Units with an open file, cwd or private bind mount under $MNT, minus $KEEP.
holders() {
  host_mounts=$(sda_mounts /proc/1/mountinfo)
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" = "$$" ] && continue
    busy=0
    for l in "$p"/cwd "$p"/root "$p"/fd/*; do
      case "$(readlink "$l" 2>/dev/null)" in "$MNT" | "$MNT"/*) busy=1; break ;; esac
    done
    # A private bind of sda1 the host lacks is what keeps e2fsck "in use".
    [ "$busy" = 1 ] || [ "$(sda_mounts "$p/mountinfo")" = "$host_mounts" ] || busy=1
    [ "$busy" = 1 ] || continue
    u=$(sed -n 's#^0::.*/\([^/]*\.\(service\|scope\)\)$#\1#p' "$p/cgroup" | head -1)
    [ -n "$u" ] && ! [[ $u =~ $KEEP ]] && echo "$u"
  done | sort -u
}

cut() {
  [ -s "$list" ] || { echo "$list is empty: nothing to cut"; exit 0; }
  report || [ "${ALLOW_USED:-0}" = 1 ] || { echo "bad blocks still hold files (see above): delete them or ALLOW_USED=1" >&2; exit 1; }
  state=$(mktemp /var/tmp/cutout-units.XXXXXX)
  mounts=$(systemctl list-units 'mnt-data*.mount' --all --plain --no-legend | awk '{print $1}')
  # shellcheck disable=SC2086
  systemctl mask --runtime $mounts
  trap 'systemctl unmask --runtime $mounts 2>/dev/null; systemctl start $mounts 2>/dev/null; xargs -a "$state" -r systemctl start' EXIT

  for i in 1 2 3 4 5; do
    units=$( { holders; systemctl list-units 'papra*' --plain --no-legend | awk '{print $1}'; } | sort -u)
    [ -z "$units" ] && break
    echo "stopping: $units"
    echo "$units" >> "$state"
    # shellcheck disable=SC2086
    systemctl stop $units || true
    sleep 2
  done
  sort -u -o "$state" "$state"

  umount -R "$MNT" || { echo "still busy:"; fuser -vm "$MNT" 2>&1 | head -20; exit 1; }
  e2fsck -fy -l "$list" "$DEV" || [ $? -le 1 ]   # 1 = errors corrected
  dumpe2fs -b "$DEV" | wc -l | sed 's/^/bad blocks now recorded: /'
  # trap restores mounts and units
}

case $cmd in
  scan) scan ;;
  report) report ;;
  cut) cut ;;
  holders) holders ;;
  *) echo "usage: $0 scan|report|cut [LIST]" >&2; exit 1 ;;
esac
