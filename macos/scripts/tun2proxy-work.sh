#!/bin/bash
# Work Tailscale transparent routing via tun2proxy
# Starts tun2proxy, then configures routes and /etc/hosts from work tailscaled.
# Re-trigger: sudo launchctl kickstart -k system/org.nixos.tun2proxy-work

set -euo pipefail

TS="/opt/homebrew/opt/tailscale/bin/tailscale"
SOCK="/var/run/tailscale-work/tailscaled.sock"
TUN2PROXY="/opt/homebrew/opt/tun2proxy/bin/tun2proxy-bin"
GW="10.0.0.1"
MARKER="# WORK-TAILSCALE-MANAGED"

# Wait for work tailscaled
for _ in $(seq 1 30); do $TS --socket=$SOCK status >/dev/null 2>&1 && break; sleep 2; done

# Start tun2proxy in background
$TUN2PROXY --proxy socks5://127.0.0.1:1055 --dns over-tcp --dns-addr 192.168.64.10 --bypass 127.0.0.1 &
PID=$!
for _ in $(seq 1 15); do /sbin/route -n get "$GW" >/dev/null 2>&1 && break; sleep 1; done

# Single python call: extract subnets, peer IPs, and DNS names
$TS --socket=$SOCK status --json 2>/dev/null | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in (data.get('Peer') or {}).values():
    for r in (p.get('PrimaryRoutes') or []):
        print(f'SUBNET {r}')
    name = p.get('DNSName', '').rstrip('.')
    for a in (p.get('TailscaleIPs') or []):
        if ':' not in a:
            print(f'HOST {a}')
            if name: print(f'DNS {a} {name}')
" | while read -r type value extra; do
  case "$type" in
    SUBNET) /sbin/route add -net "$value" "$GW" 2>/dev/null || true ;;
    HOST)   /sbin/route add -host "$value" "$GW" 2>/dev/null || true ;;
    DNS)    echo "$value $extra $MARKER" ;;
  esac
done > /tmp/hosts.work

# Update /etc/hosts atomically
grep -v "$MARKER" /etc/hosts > /tmp/hosts.clean 2>/dev/null || true
cat /tmp/hosts.clean /tmp/hosts.work > /tmp/hosts.new
cp /tmp/hosts.new /etc/hosts
rm -f /tmp/hosts.work /tmp/hosts.clean /tmp/hosts.new

echo "tun2proxy (PID $PID) + routes + /etc/hosts configured"
wait $PID
