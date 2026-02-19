---
name: pi-admin
description: Raspberry Pi 5 system administration. Monitor resources, manage services, perform updates and maintenance.
metadata: {"openclaw":{"emoji":"🥧","requires":{"bins":["systemctl","journalctl"]}}}
---

# Raspberry Pi 5 Administration

System monitoring and administration for this NixOS RPi5.

## When to Use
- Checking system resources (CPU, memory, temperature, storage)
- Viewing running services and their status
- Checking network / Tailscale configuration
- Performing system updates or cleanup
- Troubleshooting issues

## System Overview

```bash
# Quick health check
uname -a
uptime
free -h
df -h
vcgencmd measure_temp  # CPU temperature
```

## Network

```bash
# Network interfaces and IPs
ip addr show
hostname -I

# Tailscale status
tailscale status
tailscale ip -4
```

## Resources

```bash
# CPU usage (1-second snapshot)
top -bn1 | head -20

# Memory
free -h

# Temperature
vcgencmd measure_temp

# CPU throttling / clock
vcgencmd get_throttled
vcgencmd measure_clock arm
```

## Storage

```bash
# Disk usage
df -h

# Largest directories under home
du -sh /home/nsimon/* 2>/dev/null | sort -h

# Docker volumes / images
docker system df
```

## Services

```bash
# OpenClaw gateway status
systemctl --user status openclaw-gateway
journalctl --user -u openclaw-gateway -n 50

# Home Assistant container
docker ps | grep homeassistant
docker logs homeassistant --tail 50

# All user services
systemctl --user list-units --type=service --state=running

# All system services (running)
systemctl list-units --type=service --state=running
```

## Hardware Info

```bash
# Raspberry Pi model
cat /sys/firmware/devicetree/base/model && echo

# CPU info
nproc
cat /proc/cpuinfo | grep "Model name" | head -1

# Memory
cat /proc/meminfo | grep MemTotal
```

## Maintenance

**IMPORTANT: This is a NixOS system. Package management is handled via `~/nic-os/rpi5/configuration.nix` and `nixos-rebuild`. Do NOT use `apt` or `pip`.**

```bash
# Check for NixOS updates (reads flake.lock)
nix flake update --dry-run /home/nsimon/nic-os 2>&1 | head -20

# Garbage collect old Nix generations (> 30 days)
sudo nix-collect-garbage --delete-older-than 30d

# Check disk usage by Nix store
du -sh /nix/store

# Docker cleanup
docker system prune -f

# Journal cleanup (keep 7 days)
sudo journalctl --vacuum-time=7d
```

## Reboot / Restart

```bash
# Restart OpenClaw gateway
systemctl --user restart openclaw-gateway

# Restart Home Assistant
docker restart homeassistant

# System reboot (will reconnect via Tailscale after ~60s)
sudo systemctl reboot
```

## Logs

```bash
# OpenClaw gateway logs (live)
journalctl --user -u openclaw-gateway -f

# Home Assistant logs (live)
docker logs homeassistant -f --tail 100

# System kernel messages
sudo dmesg | tail -50

# Recent login attempts
sudo journalctl -u sshd -n 20
```

## Notes

- Config lives in `~/nic-os/` — edit there and run `sudo nixos-rebuild switch --flake 'path:.#rpi5'`
- Secrets live in `~/.secrets/` — plain text, not Nix-managed
- Tailscale IP resolves as `rpi5` on the tailnet
- Home Assistant runs in Docker on port 8123
