#!/bin/bash
# Dynamic routes and /etc/hosts for work Tailscale via tun2proxy
# Queries work tailscaled for peer IPs, subnets, and MagicDNS names
# Called at boot by launchd, or manually:
#   sudo launchctl kickstart system/org.nixos.tun2proxy-work-routes

set -euo pipefail

TS="/opt/homebrew/opt/tailscale/bin/tailscale"
SOCK="/var/run/tailscale-work/tailscaled.sock"
TUN_GW="10.0.0.1"

# Wait for work tailscaled to be ready
for i in $(seq 1 30); do
  $TS --socket=$SOCK status --json >/dev/null 2>&1 && break
  sleep 2
done

STATUS=$($TS --socket=$SOCK status --json 2>/dev/null)
[ -z "$STATUS" ] && { echo "ERROR: work tailscaled not responding"; exit 1; }

# Add subnet routes advertised by work peers
echo "$STATUS" | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in (data.get('Peer') or {}).values():
    for r in (p.get('PrimaryRoutes') or []):
        print(r)
" | while read -r subnet; do
  /sbin/route add -net "$subnet" "$TUN_GW" 2>/dev/null || true
done

# Add host routes for work peer IPs (override personal tailnet's /10)
echo "$STATUS" | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in (data.get('Peer') or {}).values():
    for a in (p.get('TailscaleIPs') or []):
        if ':' not in a: print(a)
" | while read -r ip; do
  /sbin/route add -host "$ip" "$TUN_GW" 2>/dev/null || true
done

# Generate /etc/hosts entries for work MagicDNS names
MARKER="# WORK-TAILSCALE-MANAGED"
HOSTS=$(echo "$STATUS" | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in (data.get('Peer') or {}).values():
    name = p.get('DNSName', '').rstrip('.')
    for a in (p.get('TailscaleIPs') or []):
        if ':' not in a and name:
            print(f'{a} {name}')
")

# Atomic update: strip old managed lines, append new ones
grep -v "$MARKER" /etc/hosts > /tmp/hosts.work 2>/dev/null || cp /etc/hosts /tmp/hosts.work
echo "$HOSTS" | while read -r line; do
  [ -n "$line" ] && echo "$line $MARKER" >> /tmp/hosts.work
done
cp /tmp/hosts.work /etc/hosts
rm -f /tmp/hosts.work

echo "Routes and /etc/hosts updated successfully"
