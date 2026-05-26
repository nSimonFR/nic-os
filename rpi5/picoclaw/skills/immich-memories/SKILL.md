---
name: immich-memories
description: Send a Telegram reminder of today's Immich "on this day" memories, with photo attachments. Use when the user asks about Immich memories, on-this-day, or wants a recap of past photos.
homepage: https://immich.app
metadata: {"openclaw":{"emoji":"📸","requires":{"bins":["python3"]},"agenix":["immich-api-key","telegram-bot-token"]}}
---

# Immich on-this-day reminder

Sends today's Immich on-this-day memories to a Telegram chat as one album per memory (preview thumbnails) with a clickable Immich memory link in the caption. Exits silently when today has no memories with assets.

## When to use

- "show me / send me / what's on this day in Immich"
- "Immich memories" / "any photos from today in past years"
- A scheduled (cron) daily Immich digest

## Default invocation

The two secrets are already on disk as agenix files readable by the picoclaw user; the chat ID is the picoclaw owner's (numeric Telegram ID).

```bash
IMMICH_API_KEY=$(cat /run/agenix/immich-api-key) \
TELEGRAM_BOT_TOKEN=$(cat /run/agenix/telegram-bot-token) \
TELEGRAM_CHAT_ID=82389391 \
  python3 {baseDir}/scripts/immich-on-this-day.py
```

Behavior:
- Posts up to 3 memory albums (most photos first), each with up to 4 preview JPEGs and a caption `YEAR — N photos[, M videos]` + Immich link.
- If `total > 3`, a follow-up "+ N more memories" message is posted.
- If today has zero in-window memories, the script exits 0 with no output and no Telegram message.

## Useful flags

| Flag | Default | Effect |
| --- | --- | --- |
| `--dry-run` | off | Print captions + would-be attachments to stdout, do not fetch or POST. |
| `--top N` | 3 | Cap to top N memories by asset count. Set to `0` to send nothing. |
| `--attach-per-memory N` | 4 | Photos per album. Telegram caps at 10. |
| `--no-attach` | off | Send a single text-only summary (one `sendMessage`) instead of albums. |
| `--asset-preview N` | 2 | `--no-attach` mode only: filenames listed per memory in the text summary. |

## Examples

Dry-run (preview captions, no Telegram traffic):

```bash
IMMICH_API_KEY=$(cat /run/agenix/immich-api-key) \
  python3 {baseDir}/scripts/immich-on-this-day.py --dry-run
```

Text-only digest (no photo attachments, links and filename previews):

```bash
IMMICH_API_KEY=$(cat /run/agenix/immich-api-key) \
TELEGRAM_BOT_TOKEN=$(cat /run/agenix/telegram-bot-token) \
TELEGRAM_CHAT_ID=82389391 \
  python3 {baseDir}/scripts/immich-on-this-day.py --no-attach
```

Send every memory with up to 8 photos each:

```bash
IMMICH_API_KEY=$(cat /run/agenix/immich-api-key) \
TELEGRAM_BOT_TOKEN=$(cat /run/agenix/telegram-bot-token) \
TELEGRAM_CHAT_ID=82389391 \
  python3 {baseDir}/scripts/immich-on-this-day.py --top 10 --attach-per-memory 8
```

## Notes

- The script hits `http://127.0.0.1:2283/api/memories?type=on_this_day` (Immich's socket-activated proxy). The first request wakes the backend; subsequent calls are fast.
- Memory links in captions use `https://rpi5.gate-mintaka.ts.net:10000` (Tailscale Funnel) so they open on phones. Photos in the album are uploaded as bytes to Telegram, not URLs — Telegram-side previews are independent of Immich auth.
- Override the Immich endpoints with `IMMICH_INTERNAL_URL=` / `IMMICH_PUBLIC_URL=` if running against a different instance.
- Videos count toward the per-memory `count` phrase but are not attached as album items (Telegram would need the full video binary; the user can tap the memory link to view them in Immich).
