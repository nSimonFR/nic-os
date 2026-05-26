---
name: immich-memories
description: Query today's Immich "on this day" memories and print a summary picoclaw can relay. Use when the user asks about Immich memories, on-this-day, or a recap of past photos from today's date.
homepage: https://immich.app
metadata: {"openclaw":{"emoji":"📸","requires":{"bins":["python3"]},"agenix":["immich-api-key"]}}
---

# Immich on-this-day reminder

Queries Immich's on-this-day memories for the current calendar day and prints a compact summary (year + photo/video counts + clickable Immich link per memory). Picoclaw reads the stdout and relays it to the user — the script does not call Telegram itself.

Empty stdout means today has no memories with assets; relay something like "no Immich memories for today" in that case.

## When to use

- "show me / what's on this day in Immich"
- "Immich memories" / "any photos from today in past years"
- A scheduled (cron) daily Immich digest where picoclaw owns the Telegram message

## Default invocation

`immich-api-key` is an agenix file on disk readable by the picoclaw user.

```bash
IMMICH_API_KEY=$(cat /run/agenix/immich-api-key) \
  python3 {baseDir}/scripts/immich-on-this-day.py
```

Sample stdout (today has memories):

```
📸 Immich on this day

3 memories today

• 2021 — 12 photos
  https://rpi5.gate-mintaka.ts.net:10000/memory/<id>
  · IMG_5656.PNG — 2021-05-26
  · IMG_5657.PNG — 2021-05-26

• 2023 — 4 photos, 1 video
  https://rpi5.gate-mintaka.ts.net:10000/memory/<id>
  · VID_1234.MOV — 2023-05-26
  · IMG_5658.PNG — 2023-05-26

• 2025 — 1 photo
  https://rpi5.gate-mintaka.ts.net:10000/memory/<id>
  · IMG_5659.PNG — 2025-05-26
```

## Flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--top N` | 3 | Cap to top N memories by asset count. |
| `--asset-preview N` | 2 | Text mode: filenames listed per memory. |
| `--json` | off | Structured JSON output with full asset list and `asset_url` for each photo/video. |

## JSON mode

Use when you need to programmatically pick specific assets to act on (e.g. quote a particular photo back to the user):

```bash
IMMICH_API_KEY=$(cat /run/agenix/immich-api-key) \
  python3 {baseDir}/scripts/immich-on-this-day.py --json --top 5
```

Shape: `{ "total": N, "shown": M, "memories": [{id, year, photos, videos, memory_url, assets: [{id, filename, type, fileCreatedAt, asset_url}]}] }`. JSON mode always prints (`{"total": 0, ...}` on empty days) so callers don't have to handle empty stdout specially.

## Notes

- Internal API call hits `http://127.0.0.1:2283/api/memories?type=on_this_day` (Immich's socket-activated proxy). The first request wakes the backend; subsequent calls are fast.
- `memory_url` / `asset_url` use `https://rpi5.gate-mintaka.ts.net:10000` (Tailscale Funnel) so the links open from phones. Override via `IMMICH_INTERNAL_URL=` / `IMMICH_PUBLIC_URL=` for a different instance.
- Immich generates today's memories overnight via NightlyJobs. If the script runs before that job has fired (e.g. the backend was asleep through the boundary), the output may be empty even when photos for today exist; in that case re-run after a few minutes.
