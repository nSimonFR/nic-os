---
name: telegram
description: Send a Telegram message or photo from this machine via the bot — to Nico's DM, Alfie's DM, or the shared group. Use when asked to notify/ping/message someone on Telegram, or to post an update/result there.
metadata:
  short-description: Post to Telegram via the `telegram-send` command
---

# Telegram

Post messages and photos to Telegram with `telegram-send`. **Outbound only** —
Hermes owns incoming messages.

Do **not** hand-roll `curl https://api.telegram.org/...`. `telegram-send` wraps
the same script every systemd sender uses (`shared/scripts/telegram-send.sh`),
so token lookup, urlencoding, parse modes and timeouts are already handled —
and the bot token never lands in a command line or shell transcript.

```
telegram-send [-c CHAT] [-m html|markdown|plain] [-p PHOTO] [TEXT]
```

`TEXT` is read from stdin when omitted; with `-p` it becomes the caption. The
raw API response is printed, so check it: `telegram-send "hi" | jq .ok`.

## Targets (`-c`)

| Alias | chat_id | Who |
| --- | --- | --- |
| me / Nico | `82389391` | Nico's DM — **default**, no `-c` needed |
| alfie | `8627259779` | Alfie's DM |
| group | `-1003356011841` | Group "nSimon, ServaTilis and Alfie" |

Default to Nico's DM. The **group is shared with Alfie** — only post there when
both should see it. (It triggers Hermes only on @mention, so a plain post won't
start an agent turn.)

## Recipes

```bash
telegram-send "Backup finished — 4.2 GB in 11 min"
telegram-send -c -1003356011841 "<b>Deploy</b> done — <code>gen-812</code>"
telegram-send -p /path/to/image.jpg "Optional caption"

# Multi-line / emoji: pipe it in, rather than fighting shell quoting.
telegram-send <<'EOF'
✅ Deploy finished
• tests: 42 passed
EOF

# Byte-for-byte output (log excerpts, paths, anything with < & *) needs plain,
# or Telegram rejects it as bad HTML.
journalctl -u sure-web -n 20 --no-pager | telegram-send -m plain
```

## Notes

- `telegram-send` is one-shot. If you are writing a *service*, `shared/notify.nix`
  has the other two seams: `alert` for a condition that later clears
  (self-updating message, auto-resolve) and `agent` for chatter that should batch.
- Failures are best-effort: it warns on stderr and exits 0 so a notification
  never fails its caller. Surface Telegram's `description` when `.ok` is false.
- Galleries (2–10 photos as one `sendMediaGroup`) aren't covered; reference
  implementation is `send_album` in
  `rpi5/hermes/skills/immich-memories/scripts/immich-on-this-day.py`.
- Never echo the bot token back to the user or into logs.
