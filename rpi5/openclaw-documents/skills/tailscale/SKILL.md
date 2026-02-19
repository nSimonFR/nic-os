---
name: tailscale
version: 1.0.0
description: Manage Tailscale tailnet via CLI and API. Use when the user asks to "check tailscale status", "list tailscale devices", "ping a device", "send file via tailscale", "tailscale funnel", "create auth key", "check who's online", or mentions Tailscale network management.
---

# Tailscale Skill

Manage your Tailscale tailnet via CLI. This RPi5 is already a Tailscale node (MagicDNS: `rpi5`).

## Local Operations (CLI)

These work on the current machine only.

### Status & Diagnostics

```bash
# Current status (peers, connection state)
tailscale status
tailscale status --json | jq '.Peer | to_entries[] | {name: .value.HostName, ip: .value.TailscaleIPs[0], online: .value.Online}'

# Network diagnostics (NAT type, DERP, UDP)
tailscale netcheck
tailscale netcheck --format=json

# Get this machine's Tailscale IP
tailscale ip -4

# Identify a Tailscale IP
tailscale whois 100.x.x.x
```

### Connectivity

```bash
# Ping a peer (shows direct vs relay)
tailscale ping <hostname-or-ip>

# Connect/disconnect
tailscale up
tailscale down

# Use an exit node
tailscale up --exit-node=<node-name>
tailscale exit-node list
tailscale exit-node suggest
```

### File Transfer (Taildrop)

```bash
# Send files to a device
tailscale file cp myfile.txt <device-name>:

# Receive files (moves from inbox to directory)
tailscale file get ~/Downloads
tailscale file get --wait ~/Downloads  # blocks until file arrives
```

### Expose Services

```bash
# Share locally within tailnet (private)
tailscale serve 3000
tailscale serve https://localhost:8080

# Share publicly to internet
tailscale funnel 8080

# Check what's being served
tailscale serve status
tailscale funnel status
```

### SSH

```bash
# SSH via Tailscale (uses MagicDNS)
tailscale ssh user@hostname

# Enable SSH server on this machine
tailscale up --ssh
```

## Tailnet-Wide Operations (API)

For tailnet-wide management, use the Tailscale API directly:

```bash
# Set your API key (from Tailscale Admin Console → Settings → Keys)
TAILSCALE_API_KEY="tskey-api-k..."
TAILSCALE_TAILNET="-"  # auto-detect, or use org name / email domain

# List all devices
curl -s "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/devices" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}" | jq '.devices[] | {name: .hostname, ip: .addresses[0], online: .online}'

# Check who's online
curl -s "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/devices" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}" | jq '.devices[] | select(.online == true) | .hostname'

# Create auth key (reusable)
curl -s -X POST "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/keys" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":false,"tags":["tag:server"]}}}}'

# List auth keys
curl -s "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/keys" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}" | jq '.keys[] | {id, description, expires}'

# Get DNS config
curl -s "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/dns/preferences" \
  -H "Authorization: Bearer ${TAILSCALE_API_KEY}"
```

## Common Use Cases

**"Who's online right now?"**
```bash
tailscale status --json | jq '.Peer | to_entries[] | select(.value.Online == true) | .value.HostName'
```

**"Send this file to my phone"**
```bash
tailscale file cp document.pdf my-phone:
```

**"Expose my dev server publicly"**
```bash
tailscale funnel 3000
```

**"Is the connection direct or relayed?"**
```bash
tailscale ping my-server
```

## Notes

- The API key can be stored in `~/.secrets/tailscale-api-key`
- This RPi5 is configured as a Tailscale server with subnet routing and exit node support
- MagicDNS resolves `rpi5` to this machine's Tailscale IP
