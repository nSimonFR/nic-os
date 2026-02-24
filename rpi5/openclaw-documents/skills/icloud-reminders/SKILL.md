---
name: icloud-reminders
description: Sync iCloud Reminders to OpenClaw via CalDAV.
metadata:
  openclaw:
    requires:
      bins: ["vdirsyncer"]
      env: ["ICLOUD_EMAIL", "ICLOUD_APP_PASSWORD"]
---

# iCloud Reminders Integration

Sync iCloud Reminders to OpenClaw via CalDAV (CalDAV VTODO format).

## What You Need to Configure

1. **Apple ID + App-Specific Password**
   - Go to appleid.apple.com → Security → App-specific passwords
   - Create password labeled "rpi5-caldav"
   - Store in `~/.secrets/openclaw.env`:
     ```bash
     ICLOUD_EMAIL="your-apple-id@icloud.com"
     ICLOUD_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
     ```

2. **CalDAV Server Details**
   - iCloud CalDAV URL: `https://caldav.icloud.com/`
   - Reminders collection: `/calendars/caldav/Reminders/`
   - Full URL: `https://<ICLOUD_EMAIL>@caldav.icloud.com/calendars/caldav/Reminders/`

3. **Sync Schedule**
   - Edit `~/.openclaw/workspace/cron-icloud-sync.nix` to set sync interval
   - Default: every 15 minutes
   - Can adjust based on your needs

## How It Works

1. **vdirsyncer** syncs iCloud Reminders (VTODO) to local cache (`~/.cache/icloud-reminders/`)
2. **Sync script** processes reminders and creates OpenClaw events/reminders
3. **Cron job** runs periodically (configurable)
4. **OpenClaw** announces new reminders via chat

## Manual Sync

```bash
vdirsyncer discover icloud_reminders
vdirsyncer sync
# Check results:
cat ~/.cache/icloud-reminders/*/
```

## Troubleshooting

- **Auth fails**: Verify app-specific password (not main iCloud password)
- **No reminders sync**: Check CalDAV URL and ensure Reminders is enabled on iCloud
- **Cron not running**: Check systemd timer: `systemctl --user status openclaw-icloud-sync.timer`
