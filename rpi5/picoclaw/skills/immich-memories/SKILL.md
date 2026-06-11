---
name: immich-memories
description: Download today's Immich "on this day" photos as JPGs and send copies into the chat (via send_file). Use when the user asks about Immich memories, on-this-day, or a recap of past photos from today's date.
homepage: https://immich.app
metadata: {"openclaw":{"emoji":"📸","requires":{"bins":["python3"]},"agenix":["immich-api-key"]}}
---

# Immich on-this-day reminder

Downloads today's on-this-day photos as JPGs and prints a JSON manifest. You then
send each photo into the chat as a **copy** (not a link) using the built-in
`send_file` tool, plus a short caption message.

## When to use

- "show me / what's on this day in Immich"
- "Immich memories" / "any photos from today in past years"
- A scheduled (cron) daily Immich digest where picoclaw sends the photos

## Default invocation

Run it plainly — the script reads the API key from `/run/agenix/immich-api-key`
itself when `IMMICH_API_KEY` is unset:

```bash
python3 {baseDir}/scripts/immich-on-this-day.py --download
```

Do **not** prefix it with `IMMICH_API_KEY=$(cat /run/agenix/immich-api-key)`:
picoclaw's exec safety guard blocks any `$(...)` command substitution, so that
form fails. The script's built-in key-file read avoids the substitution entirely.

This downloads the photos and prints a JSON manifest, e.g.:

```json
{
  "caption": "📸 Immich on this day\n\n3 memories today\n\n• 2021 — 12 photos (showing 4 of 12)\n• 2023 — 4 photos, 1 video\n• 2025 — 1 photo",
  "files": [
    "/tmp/immich-on-this-day/2021_00_IMG_5656.jpg",
    "/tmp/immich-on-this-day/2021_01_IMG_5657.jpg",
    "/tmp/immich-on-this-day/2025_05_IMG_5659.jpg"
  ],
  "photos_sent": 3,
  "videos_skipped": 1,
  "memories_total": 3
}
```

## What to do with the manifest

1. Send `caption` as a normal text message to the user.
2. For **each** path in `files`, call the `send_file` tool with that `path`
   (absolute path; just pass it through). Each call delivers one JPG into the chat.
3. If `files` is empty but `caption` is non-empty (e.g. today's memories are all
   videos), just send the caption. If `memories_total` is 0, relay something like
   "no Immich memories for today".

Defaults already keep the volume sane: top 3 memories, ≤ 4 photos each, **10 photos
max** total. Videos are skipped (counted in `videos_skipped`), and the caption notes
any per-memory cap ("showing 4 of 12"). Don't raise the caps unless the user asks.

## Flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--download` | off | Download photos as JPGs + print the JSON manifest above (the mode this skill uses). |
| `--download-dir DIR` | `<tmp>/immich-on-this-day` | Where JPGs are written. Wiped + recreated every run (self-cleaning). |
| `--per-memory N` | 4 | Download mode: max photos per memory. |
| `--max-total N` | 10 | Download mode: hard cap on total photos. |
| `--top N` | 3 | Cap to top N memories by asset count. |
| `--asset-preview N` | 2 | Text mode only: filenames listed per memory. |
| `--json` | off | Link-based structured JSON (no download) — for ad-hoc lookups. |

Without `--download` or `--json` the script prints the legacy human-readable text
summary with Immich links — handy for a quick "what's on this day?" answer when the
user does not want the photos sent.

## Notes

- Photos come from `http://127.0.0.1:2283/api/assets/<id>/thumbnail?size=preview`
  (Immich's socket-activated proxy). `preview` always re-encodes to JPEG (~200–900 KB),
  so HEIC/PNG originals still arrive as a `.jpg` — well under `send_file`'s 20 MB limit.
  The first request wakes the backend; subsequent calls are fast.
- The download dir is wiped at the start of every `--download` run, so yesterday's
  photos never accumulate (bounded to ~one day, a few MB).
- Override the instance via `IMMICH_INTERNAL_URL=` (download/API) and
  `IMMICH_PUBLIC_URL=` (links used by text/`--json` modes only).
- Immich generates today's memories overnight via NightlyJobs. If the script runs
  before that job has fired (e.g. the backend was asleep through the boundary), the
  output may be empty even when photos for today exist; re-run after a few minutes.
