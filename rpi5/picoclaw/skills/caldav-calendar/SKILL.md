<!-- vendored via `npx skills add sundial-org/awesome-openclaw-skills@caldav-calendar` (commit b80cde2) -->
---
name: caldav-calendar
description: Sync and query the user's personal Nextcloud calendar via CalDAV using vdirsyncer + khal. Events cached locally as .ics under ~/.local/share/vdirsyncer/calendars/.
metadata: {"openclaw":{"emoji":"📅","os":["linux"],"requires":{"bins":["vdirsyncer","khal"]}}}
---

# CalDAV Calendar (vdirsyncer + khal)

> **PERSONAL calendar only.** This skill is wired to the user's Nextcloud (`https://rpi5.gate-mintaka.ts.net:8085`). Work/Trusk calendar access goes through the `gog` skill instead.

**vdirsyncer** syncs CalDAV calendars to local `.ics` files. **khal** reads and writes them. On the rpi5 both binaries come from `home.packages` and the configs (`~/.config/vdirsyncer/config`, `~/.config/khal/config`) are Nix-managed in `rpi5/picoclaw/picoclaw.nix`; the Nextcloud password is read at sync time from `/run/agenix/nextcloud-homepage-password` via vdirsyncer's `password.fetch`.

## Sync First

Always sync before querying or after making changes:
```bash
vdirsyncer sync
```

## View Events

```bash
khal list                        # Today
khal list today 7d               # Next 7 days
khal list tomorrow               # Tomorrow
khal list 2026-01-15 2026-01-20  # Date range
khal list -a nextcloud today     # Specific calendar
```

## Search

```bash
khal search "meeting"
khal search "dentist" --format "{start-date} {title}"
```

## Create Events

```bash
khal new 2026-01-15 10:00 11:00 "Meeting title"
khal new 2026-01-15 "All day event"
khal new tomorrow 14:00 15:30 "Call" -a nextcloud
khal new 2026-01-15 10:00 11:00 "With notes" :: Description goes here
```

After creating, sync to push changes:
```bash
vdirsyncer sync
```

## Edit Events (interactive)

`khal edit` is interactive — requires a TTY. Use tmux if automating:

```bash
khal edit "search term"
khal edit -a nextcloud "search term"
khal edit --show-past "old event"
```

Menu options:
- `s` → edit summary
- `d` → edit description
- `t` → edit datetime range
- `l` → edit location
- `D` → delete event
- `n` → skip (save changes, next match)
- `q` → quit

After editing, sync:
```bash
vdirsyncer sync
```

## Delete Events

Use `khal edit`, then press `D` to delete.

## Output Formats

For scripting:
```bash
khal list --format "{start-date} {start-time}-{end-time} {title}" today 7d
khal list --format "{uid} | {title} | {calendar}" today
```

Placeholders: `{title}`, `{description}`, `{start}`, `{end}`, `{start-date}`, `{start-time}`, `{end-date}`, `{end-time}`, `{location}`, `{calendar}`, `{uid}`

## Caching

khal caches events in `~/.local/share/khal/khal.db`. If data looks stale after syncing:
```bash
rm ~/.local/share/khal/khal.db
```

## Initial Setup (rpi5)

On this host both configs are already Nix-managed (see `rpi5/picoclaw/picoclaw.nix` — `home.file.".config/vdirsyncer/config"` and `home.file.".config/khal/config"`). Do **not** hand-edit them; changes get overwritten on the next `home-manager switch`. Edit the Nix module instead.

Bootstrap, once interactively:

```bash
vdirsyncer discover   # asks y/N per Nextcloud calendar — accept the ones you want
vdirsyncer sync
```

Afterwards `vdirsyncer sync` and all `khal …` commands work non-interactively.

Useful paths:
- Local cache: `~/.local/share/vdirsyncer/calendars/<calendar>/*.ics`
- vdirsyncer status: `~/.local/share/vdirsyncer/status/`
- khal db: `~/.local/share/khal/khal.db`
- Source of truth: `https://rpi5.gate-mintaka.ts.net:8085/remote.php/dav/`
