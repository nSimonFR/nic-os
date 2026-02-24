# iCloud Reminders Integration Setup

This guide walks through enabling iCloud Reminders sync on rpi5 via CalDAV.

## Prerequisites

- Apple ID with 2FA enabled (required for app-specific passwords)
- OpenClaw running on rpi5
- `vdirsyncer` installed (included in this branch)

## Configuration Steps

### 1. Create Apple App-Specific Password

1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign in → Security → App-specific passwords
3. Select "Mac" and "Other (custom)"
4. Label it: `rpi5-caldav`
5. Copy the generated 16-character password

### 2. Set Environment Variables

Edit `~/.secrets/openclaw.env`:

```bash
# Add these lines
ICLOUD_EMAIL="your-apple-id@icloud.com"
ICLOUD_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

Replace:
- `your-apple-id@icloud.com` with your actual iCloud email
- `xxxx-xxxx-xxxx-xxxx` with the app-specific password (hyphens included)

### 3. Enable in NixOS Config

Edit `~/nic-os/rpi5/configuration.nix`, add to `imports`:

```nix
./icloud-reminders.nix
```

### 4. Rebuild and Test

```bash
cd ~/nic-os
sudo nixos-rebuild switch --flake 'path:.#rpi5'
```

### 5. Verify Setup

Check if the sync service started:

```bash
systemctl --user status icloud-sync-reminders.timer
# Should show: "active (waiting)"

# Manual sync test:
~/.config/systemd/user/scripts-icloud-sync-reminders/bin/icloud-sync-reminders

# Check logs:
journalctl --user -u icloud-sync-reminders.service -n 50
```

### 6. Configure Sync Interval (Optional)

Edit `~/nic-os/rpi5/icloud-reminders.nix`, change timer interval:

```nix
Timer = {
  OnBootSec = "2min";
  OnUnitActiveSec = "5min";  # Change 15min → 5min for faster sync
  Persistent = true;
};
```

Then rebuild.

## Troubleshooting

### "Auth fails" / "Unauthorized"
- Verify you're using **app-specific password**, not main iCloud password
- Check credentials in `~/.secrets/openclaw.env` (no extra whitespace)
- Ensure 2FA is enabled on your Apple ID

### "No reminders found"
- Log in to iCloud.com, confirm Reminders is enabled
- Check CalDAV URL is correct: `https://caldav.icloud.com/`
- Run manual discovery: `vdirsyncer discover icloud_reminders`

### "Cron job not firing"
- Check timer: `systemctl --user list-timers | grep icloud`
- Check service: `journalctl --user -u icloud-sync-reminders.service -n 20`
- Restart: `systemctl --user restart icloud-sync-reminders.timer`

## Next Steps

- OpenClaw cron integration (announce synced reminders via chat)
- Smart filtering (only high-priority reminders)
- Custom reminder aggregation scripts

## Reverting

If you need to disable:

```bash
# Comment out in ~/nic-os/rpi5/configuration.nix:
# ./icloud-reminders.nix

sudo nixos-rebuild switch --flake 'path:.#rpi5'

# Remove credentials:
# Edit ~/.secrets/openclaw.env, delete ICLOUD_* lines
systemctl --user restart openclaw-gateway
```
