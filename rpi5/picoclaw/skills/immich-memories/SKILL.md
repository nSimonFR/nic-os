---
name: immich-memories
description: Post today's Immich "on this day" photos to Telegram as a single gallery (album). Use when the user asks about Immich memories, on-this-day, or a recap of past photos from today's date.
homepage: https://immich.app
metadata: {"openclaw":{"emoji":"📸","requires":{"bins":["python3"]},"agenix":["immich-api-key","telegram-bot-token"]}}
---

# Immich on-this-day reminder

Downloads today's on-this-day photos as JPGs and posts them to Telegram as **one
media group (a gallery)**, with a summary caption on the first photo. The script
sends the gallery itself via the Telegram Bot API — picoclaw can't build albums
(it would send each photo as a separate message).

## When to use

- "show me / what's on this day in Immich"
- "Immich memories" / "any photos from today in past years"
- A scheduled (cron) daily Immich digest

## Default invocation

Run it plainly — the script reads the Immich key from `/run/agenix/immich-api-key`,
the bot token from `/run/agenix/telegram-bot-token`, and the chat from
`$TELEGRAM_CHAT_ID` (exported for the picoclaw service), all by itself:

```bash
python3 {baseDir}/scripts/immich-on-this-day.py --send-album
```

Do **not** prefix it with `IMMICH_API_KEY=$(cat ...)` or similar: picoclaw's exec
safety guard blocks any `$(...)` command substitution, so that form fails. The
script's built-in file reads avoid the substitution entirely.

**That single command delivers everything** — the photos as a gallery and the
caption. After it succeeds (it prints e.g. `sent album of 4 photos to chat …`),
**do not** call `send_file` and **do not** re-send the caption. Just reply with a
short confirmation (or nothing). On a non-zero exit, relay the error line it printed.

If today has no memories it prints `no memories today; nothing sent` and sends
nothing — relay "no Immich memories for today".

## Flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--send-album` | off | Download photos + post them to Telegram as one gallery (the mode this skill uses). |
| `--chat-id ID` | `$TELEGRAM_CHAT_ID` | `--send-album` recipient chat. |
| `--per-memory N` | 4 | Max photos per memory. |
| `--max-total N` | 10 | Hard cap on total photos (Telegram albums max out at 10). |
| `--top N` | 3 | Cap to top N memories by asset count. |
| `--download` | off | Just download + print a JSON manifest `{caption, files, …}`, no send (for testing). |
| `--json` | off | Link-based structured JSON, no download — for ad-hoc text lookups. |
| `--asset-preview N` | 2 | Text mode only: filenames listed per memory. |

Without `--send-album`/`--download`/`--json` the script prints the legacy
human-readable text summary with Immich links — handy for a quick "what's on this
day?" text answer when the user does not want the photos sent.

## Notes

- Album = 2–10 items shown as a grid. With exactly 1 photo the script falls back to
  a single photo+caption; with 0 photos but a caption (an all-video day) it sends
  the caption as a text message.
- Photos come from `http://127.0.0.1:2283/api/assets/<id>/thumbnail?size=preview`
  (Immich's socket-activated proxy). `preview` always re-encodes to JPEG (~200–900 KB),
  so HEIC/PNG originals still arrive as a `.jpg`. The first request wakes the backend.
- Volume is bounded: top 3 memories, ≤ 4 photos each, **10 max**; videos are skipped
  (noted in the caption); per-memory caps are surfaced ("showing 4 of 12"). Don't
  raise the caps unless the user asks.
- The download dir (`<tmp>/immich-on-this-day`) is wiped at the start of every run,
  so photos never accumulate (a few MB, one day).
- Overrides: `TELEGRAM_BOT_TOKEN` / `TELEGRAM_BOT_TOKEN_FILE` (token),
  `IMMICH_INTERNAL_URL` (Immich API), `IMMICH_PUBLIC_URL` (links in text/`--json`).
- Immich generates today's memories overnight via NightlyJobs. If the script runs
  before that job has fired (backend asleep through the boundary), the result may be
  empty even when photos for today exist; re-run after a few minutes.
