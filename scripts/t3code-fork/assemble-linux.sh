#!/usr/bin/env bash
# Build the fork's linux-arm64 archive: upstream's archive (node_modules,
# resource-monitor, lib) with `t3` and `client/` swapped for the fork's.
#
#   assemble-linux.sh OFFICIAL_TGZ T3_BINARY CLIENT_DIR OUT_TGZ
set -euo pipefail

official=$(realpath "$1")
binary=$(realpath "$2")
client=$(realpath "$3")
out=$(realpath -m "$4")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$official" -C "$work"
root=$(find "$work" -mindepth 1 -maxdepth 1 -type d)

install -m 0755 "$binary" "$root/t3"
rm -rf "$root/client"
cp -r "$client" "$root/client"
find "$root/client" -name '*.map' -delete

tar --hard-dereference -czf "$out" -C "$work" "$(basename "$root")"
