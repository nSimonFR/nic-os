---
name: caldav-calendar
description: Read and write the user's personal Nextcloud calendar over CalDAV using the bundled zero-dependency nc-cal.py client (add/list/edit/delete events, list calendars). No sync step, no local cache — reads and writes go straight to the server.
metadata: {"hermes":{"emoji":"📅","os":["linux"],"requires":{"bins":["python3"]}}}
---

# CalDAV Calendar (nc-cal.py)

> **PERSONAL calendar only.** Wired to the user's Nextcloud
> (`https://rpi5.gate-mintaka.ts.net/nextcloud`). Work/Trusk calendar access
> goes through the `gog` skill instead.

`scripts/nc-cal.py` is a small, standard-CalDAV (RFC 4791) client using only the
Python standard library. It talks straight to the server on every call — there
is **no `sync` step, no local cache, and no config file to keep in order**.
Everything server-specific is defaulted for this machine (Nextcloud URL, user
`nsimon`, password read from the agenix file `/run/agenix/nextcloud-homepage-password`),
overridable via `CALDAV_BASE` / `CALDAV_USER` / `CALDAV_PASSWORD[_FILE]` /
`CALDAV_CALENDAR` env vars.

Run it with:

```bash
python3 ~/.hermes/skills/caldav-calendar/scripts/nc-cal.py <command> [options]
```

## List calendars

```bash
nc-cal.py calendars            # prints "collection-id<TAB>Display Name"
```
The default calendar is `personal`; pass `--calendar <id>` to any command to
target another (use the collection-id from the left column, e.g. `personal`).

## View events

```bash
nc-cal.py list                                   # next 30 days (default)
nc-cal.py list --from 2026-08-01 --to 2026-08-31 # explicit range
nc-cal.py list --calendar personal --json        # machine-readable
```
Output is time-sorted; each event prints its `uid:` (needed for edit/delete).

## Add an event

```bash
# timed event (local time, HH:MM)
nc-cal.py add --summary "Dentist" --start 2026-08-15T10:00 --end 2026-08-15T11:00

# all-day (a bare date, or add --all-day)
nc-cal.py add --summary "Holiday" --start 2026-08-20 --all-day

# with extras
nc-cal.py add --summary "Call" --start 2026-08-15T14:00 --end 2026-08-15T14:30 \
  --location "Zoom" --description "Sync with X" --calendar personal
```
Prints the new `uid`. A missing/invalid `--end` defaults to +1h (timed) or the
next day (all-day), so the server never rejects a zero-length event.

## Edit an event (non-interactive)

```bash
nc-cal.py edit --uid <uid> --summary "New title"
nc-cal.py edit --uid <uid> --start 2026-08-15T11:00 --end 2026-08-15T12:00
```
Fetches the event, applies only the flags you pass, and PUTs it back. Get the
`uid` from `list`.

## Delete an event

```bash
nc-cal.py delete --uid <uid>
```

## Notes

- Times without a timezone offset are floating local time (the server shows them
  in the viewer's zone). Append an offset (`2026-08-15T10:00+02:00`) to pin UTC.
- Dates are `YYYY-MM-DD`; datetimes are `YYYY-MM-DDTHH:MM`.
- Recurring events list at their next occurrence with the master `uid`.
