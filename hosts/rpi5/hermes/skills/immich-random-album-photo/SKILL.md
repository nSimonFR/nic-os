---
name: immich-random-album-photo
description: "Use when sending a random photo from a named Immich album."
version: 1.0.0
---

# Random Immich Album Photo

## When to use

Use when Nico asks for a random photo from an Immich album, especially to send it in Telegram.

## Workflow

1. Read `/run/agenix/immich-api-key` inside a script; never print it.
2. Find the album by case-insensitive exact name first, then a case-insensitive substring match through:

```bash
curl -fsS -H "x-api-key: $API_KEY" \
  'http://127.0.0.1:2283/api/albums?withAssets=false'
```

3. If no unique album match exists, ask which album to use. Do not guess.
4. Retrieve album assets with the **plural** filter key. `albumId` is ignored by the metadata endpoint; use `albumIds`:

```bash
curl -fsS -X POST -H "x-api-key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"albumIds":["<album-id>"],"size":250}' \
  'http://127.0.0.1:2283/api/search/metadata'
```

Read candidates from `.assets.items`. Confirm `.assets.total` matches the album's `assetCount` when practical.

5. Randomly choose only an item where `type == "IMAGE"`, using `secrets.choice` / `SystemRandom`, not a seeded PRNG. If no image exists, say so; do not send video.
6. **Do not retain a local copy.** For Telegram delivery, stream the preview bytes directly from Immich to the Telegram Bot API as an in-memory multipart upload. Read the bot token from `/run/agenix/telegram-bot-token`; never print it and never write the image to disk.

   **Routing:** always send to the current conversation using `$HERMES_SESSION_CHAT_ID`. Never use a hard-coded personal/home-DM chat ID. If that variable is unavailable, stop and ask rather than guessing. This preserves group/topic delivery. Verify the Telegram response `result.chat.id` equals `$HERMES_SESSION_CHAT_ID` as well as HTTP success.

7. If direct Telegram delivery is unavailable, ask before using a temporary local file. Do not use `MEDIA:` by default because it requires a local file. If the user explicitly approves a temporary file, delete it immediately after confirmed delivery.

Do not disclose API keys, bot tokens, or private filesystem paths.

## Pitfalls

- `GET /api/albums/<id>?withAssets=true` may return only album metadata on this Immich version. Use `POST /api/search/metadata` with `albumIds`.
- `albumId` (singular) can silently return the entire library. Only `albumIds` restricts results.
- An album’s thumbnail is not a random album asset.
- Do not write or retain local photo copies. Stream to Telegram in memory; use a temporary file only after explicit approval, then delete it after delivery.

## Verification

- Album name matched uniquely.
- Search response is restricted to that album (`assets.total == album assetCount`).
- Selected object is an IMAGE.
- Preview download is a nonempty JPEG.
- Telegram HTTP response is successful and `result.chat.id` equals `$HERMES_SESSION_CHAT_ID`.
- No photo bytes were written to disk.
