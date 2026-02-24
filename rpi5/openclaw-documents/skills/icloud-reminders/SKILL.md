---
name: icloud-reminders
description: Sync iCloud Reminders via CalDAV + vdirsyncer.
metadata:
  openclaw:
    requires:
      bins: ["vdirsyncer"]
      env: ["ICLOUD_EMAIL", "ICLOUD_APP_PASSWORD"]
---

# iCloud Reminders

Sync iCloud Reminders to local cache via CalDAV (vdirsyncer).

## Setup

### 1. Apple App-Specific Password
- Go to [appleid.apple.com](https://appleid.apple.com) → Security → App-specific passwords
- Select "Mac" / "Other (custom)"
- Label: `rpi5-caldav`
- Copy the 16-char password

### 2. Add Credentials
Edit `~/.secrets/openclaw.env`:
```bash
ICLOUD_EMAIL="your-apple-id@icloud.com"
ICLOUD_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

### 3. Enable Module
Edit `~/nic-os/rpi5/configuration.nix`, add to imports:
```nix
./icloud-reminders.nix
```

Rebuild:
```bash
cd ~/nic-os
sudo nixos-rebuild switch --flake 'path:.#rpi5'
```

## Usage

```bash
# Discover reminders collection
vdirsyncer discover icloud_reminders

# Sync reminders
vdirsyncer sync

# View synced reminders
ls ~/.cache/icloud-reminders/
```

## Troubleshooting

- **Auth fails**: Use **app-specific password**, not main iCloud password
- **No reminders**: Ensure Reminders is enabled on iCloud.com
- **Config issues**: `vdirsyncer verify` to test credentials
