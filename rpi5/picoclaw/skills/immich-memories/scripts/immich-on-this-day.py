#!/usr/bin/env python3
"""Today's Immich on-this-day memories — send a Telegram gallery, or print a summary.

The primary mode (--send-album) downloads today's photos as JPGs and posts them as
a single Telegram media group (album/gallery) via the Bot API, with the caption on
the first photo. picoclaw can't build albums (it sends one file per message), so the
script talks to Telegram directly. --download just fetches + prints a JSON manifest
(no send); text/--json modes are kept for ad-hoc "what's on this day?" queries.

Config (env):
  IMMICH_API_KEY        the key; if unset, read from IMMICH_API_KEY_FILE
  IMMICH_API_KEY_FILE   default /run/agenix/immich-api-key (read when the var is unset)
  IMMICH_INTERNAL_URL   default http://127.0.0.1:2283
  IMMICH_PUBLIC_URL     default https://rpi5.gate-mintaka.ts.net:10000  (text/--json links only)

  --send-album only:
  TELEGRAM_BOT_TOKEN        the bot token; if unset, PICOCLAW_CHANNELS_TELEGRAM_TOKEN,
                            then read TELEGRAM_BOT_TOKEN_FILE
  TELEGRAM_BOT_TOKEN_FILE   default /run/agenix/telegram-bot-token
  TELEGRAM_CHAT_ID          recipient chat id (or pass --chat-id)
"""
import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.request
import urllib.error
from datetime import datetime, timezone


def http(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read()


def parse_iso_z(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def fetch_memories(base, api_key):
    status, _, body = http(
        f"{base}/api/memories?type=on_this_day",
        headers={"x-api-key": api_key, "Accept": "application/json"},
    )
    if status != 200:
        sys.exit(f"Immich /api/memories -> HTTP {status}: {body[:200]!r}")
    return json.loads(body)


def select_today(memories, now):
    out = []
    for m in memories:
        if m.get("type") != "on_this_day":
            continue
        try:
            show = parse_iso_z(m["showAt"])
            hide = parse_iso_z(m["hideAt"])
        except (KeyError, ValueError):
            continue
        if not (show <= now <= hide):
            continue
        if not m.get("assets"):
            continue
        out.append(m)
    return out


def count_phrase(assets):
    imgs = sum(1 for a in assets if a.get("type") == "IMAGE")
    vids = sum(1 for a in assets if a.get("type") == "VIDEO")
    parts = []
    if imgs:
        parts.append(f"{imgs} photo" + ("s" if imgs != 1 else ""))
    if vids:
        parts.append(f"{vids} video" + ("s" if vids != 1 else ""))
    if not parts:
        n = len(assets)
        parts.append(f"{n} item" + ("s" if n != 1 else ""))
    return ", ".join(parts)


def format_text(memories, public_url, top, asset_preview):
    total = len(memories)
    memories_sorted = sorted(memories, key=lambda m: len(m["assets"]), reverse=True)
    shown = memories_sorted[:top]

    lines = ["📸 Immich on this day", ""]
    lines.append(f"{total} memor{'y' if total == 1 else 'ies'} today")
    lines.append("")

    for m in shown:
        year = parse_iso_z(m["memoryAt"]).year
        phrase = count_phrase(m["assets"])
        lines.append(f"• {year} — {phrase}")
        lines.append(f"  {public_url}/memory/{m['id']}")
        for a in m["assets"][:asset_preview]:
            name = a.get("originalFileName") or a["id"]
            try:
                date = parse_iso_z(a["fileCreatedAt"]).date().isoformat()
            except (KeyError, ValueError):
                date = "?"
            lines.append(f"  · {name} — {date}")
        lines.append("")

    if total > top:
        lines.append(f"+ {total - top} more memor{'y' if total - top == 1 else 'ies'}")

    return "\n".join(lines).rstrip() + "\n"


def format_json(memories, public_url, top):
    total = len(memories)
    memories_sorted = sorted(memories, key=lambda m: len(m["assets"]), reverse=True)
    shown = memories_sorted[:top]

    return {
        "total": total,
        "shown": len(shown),
        "memories": [
            {
                "id": m["id"],
                "year": parse_iso_z(m["memoryAt"]).year,
                "photos": sum(1 for a in m["assets"] if a.get("type") == "IMAGE"),
                "videos": sum(1 for a in m["assets"] if a.get("type") == "VIDEO"),
                "memory_url": f"{public_url}/memory/{m['id']}",
                "assets": [
                    {
                        "id": a["id"],
                        "filename": a.get("originalFileName"),
                        "type": a.get("type"),
                        "fileCreatedAt": a.get("fileCreatedAt"),
                        "asset_url": f"{public_url}/photos/{a['id']}",
                    }
                    for a in m["assets"]
                ],
            }
            for m in shown
        ],
    }


def safe_filename(name):
    """Reduce an arbitrary filename to a filesystem-safe stem (no extension)."""
    stem = os.path.splitext(os.path.basename(name or ""))[0]
    stem = re.sub(r"[^A-Za-z0-9._-]", "_", stem).strip("._") or "photo"
    return stem[:64]


def download_asset(base, api_key, asset_id, dest):
    """Fetch an asset's preview JPEG to `dest`. Returns True on success.

    `thumbnail?size=preview` always re-encodes to JPEG (verified `ff d8 ff`),
    regardless of the original being HEIC/PNG/etc — the reliable "give me a jpg"
    endpoint. `size=fullsize` instead 302-redirects to the (non-JPEG) original.
    """
    status, _, body = http(
        f"{base}/api/assets/{asset_id}/thumbnail?size=preview",
        headers={"x-api-key": api_key, "Accept": "image/jpeg"},
    )
    if status != 200 or body[:3] != b"\xff\xd8\xff":
        return False
    with open(dest, "wb") as f:
        f.write(body)
    return True


def run_download(memories, base, api_key, out_dir, top, per_memory, max_total):
    """Download up to `max_total` photo JPGs (skip videos) and build a manifest.

    Returns the JSON-serialisable manifest dict consumed by picoclaw.
    """
    total_memories = len(memories)
    shown = sorted(memories, key=lambda m: len(m["assets"]), reverse=True)[:top]

    # Self-cleaning: wipe + recreate so yesterday's photos never accumulate.
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir, exist_ok=True)

    files = []
    videos_skipped = 0
    caption_lines = ["📸 Immich on this day", ""]
    caption_lines.append(
        f"{total_memories} memor{'y' if total_memories == 1 else 'ies'} today"
    )
    caption_lines.append("")

    for m in shown:
        year = parse_iso_z(m["memoryAt"]).year
        imgs = [a for a in m["assets"] if a.get("type") == "IMAGE"]
        videos_skipped += sum(1 for a in m["assets"] if a.get("type") == "VIDEO")

        remaining = max_total - len(files)
        take = imgs[: max(0, min(per_memory, remaining))]

        sent = 0
        for a in take:
            stem = safe_filename(a.get("originalFileName") or a["id"])
            dest = os.path.join(out_dir, f"{year}_{len(files):02d}_{stem}.jpg")
            if download_asset(base, api_key, a["id"], dest):
                files.append(dest)
                sent += 1

        # Per-memory caption line, with transparency notes for any cap applied.
        notes = []
        if len(take) < len(imgs):
            notes.append(f"showing {sent} of {len(imgs)}")
        elif sent < len(take):
            notes.append(f"{sent} of {len(imgs)}")  # some downloads failed
        line = f"• {year} — {count_phrase(m['assets'])}"
        if notes:
            line += f" ({'; '.join(notes)})"
        caption_lines.append(line)

    if total_memories > len(shown):
        extra = total_memories - len(shown)
        caption_lines.append(f"+ {extra} more memor{'y' if extra == 1 else 'ies'}")

    caption = "\n".join(caption_lines).rstrip() if total_memories else ""

    return {
        "caption": caption,
        "files": files,
        "photos_sent": len(files),
        "videos_skipped": videos_skipped,
        "memories_total": total_memories,
    }


def resolve_telegram_token():
    tok = (os.environ.get("TELEGRAM_BOT_TOKEN")
           or os.environ.get("PICOCLAW_CHANNELS_TELEGRAM_TOKEN"))
    if not tok:
        tok_file = os.environ.get("TELEGRAM_BOT_TOKEN_FILE", "/run/agenix/telegram-bot-token")
        try:
            with open(tok_file) as f:
                tok = f.read().strip()
        except OSError:
            tok = ""
    return tok


def tg_request(token, method, fields, files=None):
    """POST to the Telegram Bot API as multipart/form-data. Returns (ok, payload)."""
    boundary = "----immich" + os.urandom(16).hex()
    bb = boundary.encode()
    body = bytearray()
    for name, value in fields.items():
        body += b"--" + bb + b"\r\n"
        body += b'Content-Disposition: form-data; name="' + name.encode() + b'"\r\n\r\n'
        body += str(value).encode() + b"\r\n"
    for field, filename, data in (files or []):
        body += b"--" + bb + b"\r\n"
        body += ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n'
                 % (field, filename)).encode()
        body += b"Content-Type: image/jpeg\r\n\r\n"
        body += data + b"\r\n"
    body += b"--" + bb + b"--\r\n"

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as r:
            return True, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return False, json.loads(e.read())
        except Exception:
            return False, {"description": f"HTTP {e.code}"}
    except urllib.error.URLError as e:
        return False, {"description": str(e.reason)}


def send_album(token, chat_id, manifest):
    """Deliver the manifest to Telegram as one media group (gallery).

    >=2 photos -> sendMediaGroup (album, caption on the first). 1 photo ->
    sendPhoto. 0 photos but a caption (all-video day) -> sendMessage. Returns
    (ok, status_or_error_str).
    """
    files, caption = manifest["files"], manifest["caption"]

    if len(files) >= 2:
        media = [{"type": "photo", "media": f"attach://file{i}"} for i in range(len(files))]
        if caption:
            media[0]["caption"] = caption
        parts = [(f"file{i}", os.path.basename(p), open(p, "rb").read())
                 for i, p in enumerate(files)]
        ok, res = tg_request(token, "sendMediaGroup",
                             {"chat_id": chat_id, "media": json.dumps(media)}, parts)
        action = f"album of {len(files)} photos"
    elif len(files) == 1:
        fields = {"chat_id": chat_id}
        if caption:
            fields["caption"] = caption
        with open(files[0], "rb") as f:
            parts = [("photo", os.path.basename(files[0]), f.read())]
        ok, res = tg_request(token, "sendPhoto", fields, parts)
        action = "1 photo"
    elif caption:
        ok, res = tg_request(token, "sendMessage", {"chat_id": chat_id, "text": caption})
        action = "caption (no photos today)"
    else:
        return True, "no memories today; nothing sent"

    if ok and res.get("ok"):
        return True, f"sent {action} to chat {chat_id}"
    return False, f"Telegram {res.get('description', 'send failed')!r}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--send-album", action="store_true",
                    help="download today's photos and post them to Telegram as one "
                         "media group (gallery), caption on the first photo")
    ap.add_argument("--chat-id", default=os.environ.get("TELEGRAM_CHAT_ID", ""),
                    help="--send-album: recipient chat id (default $TELEGRAM_CHAT_ID)")
    ap.add_argument("--download", action="store_true",
                    help="download today's photos as JPGs and print a JSON manifest "
                         "{caption, files, ...} without sending")
    ap.add_argument("--download-dir",
                    default=os.path.join(tempfile.gettempdir(), "immich-on-this-day"),
                    help="dir to write JPGs into; wiped + recreated each run "
                         "(default: <tmp>/immich-on-this-day)")
    ap.add_argument("--per-memory", type=int, default=4,
                    help="download mode: max photos per memory (default 4)")
    ap.add_argument("--max-total", type=int, default=10,
                    help="download mode: hard cap on total photos (default 10)")
    ap.add_argument("--top", type=int, default=3,
                    help="cap to top N memories by asset count (default 3)")
    ap.add_argument("--asset-preview", type=int, default=2,
                    help="text mode: first N asset filenames listed per memory (default 2)")
    ap.add_argument("--json", action="store_true",
                    help="emit structured JSON (with links) instead of human-readable text")
    args = ap.parse_args()

    api_key = os.environ.get("IMMICH_API_KEY")
    if not api_key:
        # Read the agenix key file directly so the skill can run as a plain
        # `python3 ... --download` with no `IMMICH_API_KEY=$(cat ...)` prefix —
        # picoclaw's exec safety guard blocks any `$(...)` command substitution.
        key_file = os.environ.get("IMMICH_API_KEY_FILE", "/run/agenix/immich-api-key")
        try:
            with open(key_file) as f:
                api_key = f.read().strip()
        except OSError:
            api_key = ""
    if not api_key:
        sys.exit("set IMMICH_API_KEY, or make IMMICH_API_KEY_FILE "
                 "(default /run/agenix/immich-api-key) readable")

    internal = os.environ.get("IMMICH_INTERNAL_URL", "http://127.0.0.1:2283").rstrip("/")
    public = os.environ.get("IMMICH_PUBLIC_URL", "https://rpi5.gate-mintaka.ts.net:10000").rstrip("/")

    memories = fetch_memories(internal, api_key)
    today = select_today(memories, datetime.now(timezone.utc))

    if args.send_album or args.download:
        manifest = run_download(
            today, internal, api_key, args.download_dir,
            max(0, args.top), max(0, args.per_memory), max(0, args.max_total),
        )
        if not args.send_album:
            print(json.dumps(manifest, indent=2))
            return 0

        token = resolve_telegram_token()
        if not token:
            sys.exit("set TELEGRAM_BOT_TOKEN, or make TELEGRAM_BOT_TOKEN_FILE "
                     "(default /run/agenix/telegram-bot-token) readable")
        if not args.chat_id:
            sys.exit("set --chat-id or TELEGRAM_CHAT_ID for --send-album")
        ok, status = send_album(token, args.chat_id, manifest)
        print(status)
        return 0 if ok else 1

    if args.json:
        print(json.dumps(format_json(today, public, max(0, args.top)), indent=2))
        return 0

    if not today or args.top <= 0:
        return 0

    sys.stdout.write(format_text(today, public, args.top, args.asset_preview))
    return 0


if __name__ == "__main__":
    sys.exit(main())
