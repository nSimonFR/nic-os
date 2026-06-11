---
name: telegram
description: Send a Telegram message or photo from this machine via the bot — to Nico's DM, Alfie's DM, or the shared group. Use when asked to notify/ping/message someone on Telegram, or to post an update/result there.
metadata:
  short-description: Post to Telegram (sendMessage / sendPhoto) via the bot token
---

# Telegram

Post messages and photos to Telegram from the rpi using the bot's HTTP API.
**Outbound only** — picoclaw owns incoming messages.

## Auth

The bot token is an agenix secret on disk, readable by `nsimon`:

```bash
TOKEN=$(cat /run/agenix/telegram-bot-token)
```

(If that path is missing — e.g. a home-manager activation context — fall back to
`/run/user/$(id -u)/agenix/telegram-bot-token`.)

## Targets (chat_id)

| Alias | chat_id | Who |
| --- | --- | --- |
| me / Nico | `82389391` | Nico's DM with the bot — **default** |
| alfie | `8627259779` | Alfie's DM with the bot |
| group | `-1003356011841` | Group "nSimon, ServaTilis and Alfie" (Nico + Alfie + bot) |

Default to **Nico's DM** unless told otherwise. The **group is shared with Alfie** —
only post there when both should see it. (The group is set to trigger picoclaw only
when the bot is @mentioned, so a plain post won't start an agent turn.)

## Send a text message

```bash
TOKEN=$(cat /run/agenix/telegram-bot-token)
curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=82389391" \
  --data-urlencode "text=Your message here" | jq '{ok, id: .result.message_id}'
```

`--data-urlencode` handles spaces, newlines, and punctuation safely. Optional:
add `--data-urlencode "parse_mode=Markdown"` for *bold* / `code` (then escape any
literal `_ * [ ` characters in the text).

### Emoji / multi-line / special characters

A raw emoji typed directly in the command can make the shell fail with
`character not in range`. Put rich text in a file via a **quoted** heredoc, then
send the file with `text@`:

```bash
TOKEN=$(cat /run/agenix/telegram-bot-token)
cat > /tmp/tg-msg.txt <<'EOF'
✅ Deploy finished
• build: ok
• tests: 42 passed
EOF
curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=82389391" \
  --data-urlencode "text@/tmp/tg-msg.txt" | jq '{ok, id: .result.message_id}'
```

## Send a photo

```bash
TOKEN=$(cat /run/agenix/telegram-bot-token)
curl -s "https://api.telegram.org/bot${TOKEN}/sendPhoto" \
  -F "chat_id=82389391" \
  -F "photo=@/path/to/image.jpg" \
  -F "caption=Optional caption" | jq '{ok, id: .result.message_id}'
```

## Send a gallery (album)

For 2–10 photos as one grouped gallery, use `sendMediaGroup` (a `media` JSON array
of `{type:"photo", media:"attach://fileN"}` with the caption on item 0, plus the
files as `-F fileN=@...`). A working stdlib reference implementation lives in the
immich skill: `rpi5/picoclaw/skills/immich-memories/scripts/immich-on-this-day.py`
(`send_album`).

## Notes

- Always check the response: `{"ok":true,...}` on success; on failure Telegram
  returns `{"ok":false,"description":"..."}` — surface that description.
- Never echo the token back to the user or embed it in logs.
- This bot is the same one picoclaw runs; sending here does not go through
  picoclaw's agent (it's a direct API call).
