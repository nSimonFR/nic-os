#!/usr/bin/env python3
"""Send a Telegram reminder of today's Immich on-this-day memories.

Default mode posts one Telegram album per memory (thumbnails fetched from
Immich, captioned with year + counts + clickable memory link). Pass
``--no-attach`` to fall back to a single text message with links only.

Picoclaw owns scheduling — this script is the one-shot worker. It exits
silently with no message when today has nothing to show.

Config (env):
  IMMICH_API_KEY        required  (/run/agenix/immich-api-key)
  TELEGRAM_BOT_TOKEN    required  (/run/agenix/telegram-bot-token)  unless --dry-run
  TELEGRAM_CHAT_ID      required                                    unless --dry-run
  IMMICH_INTERNAL_URL   default http://127.0.0.1:2283
  IMMICH_PUBLIC_URL     default https://rpi5.gate-mintaka.ts.net:10000
"""
import argparse
import html
import json
import os
import secrets
import sys
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime, timezone


def http(url, method="GET", headers=None, data=None):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read()


def parse_iso_z(s):
    # Immich emits "2026-05-24T00:00:00.000Z" and "2025-05-24T10:04:05+00:00".
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


def format_message(memories, public_url, top, asset_preview):
    """Text-only summary used by --no-attach mode."""
    total = len(memories)
    memories_sorted = sorted(memories, key=lambda m: len(m["assets"]), reverse=True)
    shown = memories_sorted[:top]

    lines = ["📸 <b>Immich on this day</b>", ""]
    lines.append(f"<i>{total} memor{'y' if total == 1 else 'ies'} today</i>")
    lines.append("")

    for m in shown:
        year = parse_iso_z(m["memoryAt"]).year
        phrase = count_phrase(m["assets"])
        lines.append(f"• <b>{year}</b> — {phrase}")
        lines.append(f"  {public_url}/memory/{m['id']}")
        for a in m["assets"][:asset_preview]:
            name = html.escape(a.get("originalFileName") or a["id"])
            try:
                date = parse_iso_z(a["fileCreatedAt"]).date().isoformat()
            except (KeyError, ValueError):
                date = "?"
            lines.append(f"  · {name} — {date}")
        lines.append("")

    if total > top:
        lines.append(f"<i>+ {total - top} more memor{'y' if total - top == 1 else 'ies'}</i>")

    return "\n".join(lines).rstrip() + "\n"


def album_caption(mem, public_url, header):
    """Album caption for one memory. `header` is prepended (first memory only)."""
    year = parse_iso_z(mem["memoryAt"]).year
    phrase = count_phrase(mem["assets"])
    body = f"<b>{year}</b> — {phrase}\n{public_url}/memory/{mem['id']}"
    return (header + body) if header else body


def fetch_preview(base, api_key, asset_id):
    """Fetch a preview-sized JPEG for an asset. Returns (bytes, content_type) or None."""
    status, headers, body = http(
        f"{base}/api/assets/{asset_id}/thumbnail?size=preview",
        headers={"x-api-key": api_key},
    )
    if status != 200:
        print(f"thumbnail {asset_id}: HTTP {status}", file=sys.stderr)
        return None
    ctype = (headers.get("Content-Type") or "image/jpeg").split(";")[0].strip()
    return body, ctype


def build_multipart(fields, files):
    """fields: dict[str, str]; files: list of (name, filename, content_type, bytes)."""
    boundary = "----immich-on-this-day-" + secrets.token_hex(12)
    parts = []
    for k, v in fields.items():
        parts.append(
            f'--{boundary}\r\n'
            f'Content-Disposition: form-data; name="{k}"\r\n\r\n'
            f'{v}\r\n'.encode()
        )
    for name, filename, ctype, data in files:
        parts.append(
            f'--{boundary}\r\n'
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            f'Content-Type: {ctype}\r\n\r\n'.encode()
        )
        parts.append(data)
        parts.append(b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def send_telegram(token, chat_id, text):
    data = urllib.parse.urlencode({
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }).encode()
    status, _, body = http(
        f"https://api.telegram.org/bot{token}/sendMessage",
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=data,
    )
    if status != 200:
        sys.exit(f"Telegram sendMessage -> HTTP {status}: {body[:300]!r}")


def send_media_group(token, chat_id, caption, photos):
    """photos: list of (asset_id, filename, content_type, bytes). Caption goes on item 0."""
    media = []
    files = []
    for i, (asset_id, filename, ctype, data) in enumerate(photos):
        attach_name = f"photo{i}"
        item = {"type": "photo", "media": f"attach://{attach_name}"}
        if i == 0 and caption:
            item["caption"] = caption
            item["parse_mode"] = "HTML"
        media.append(item)
        # Strip non-ASCII chars from the multipart filename — they're not
        # encoded reliably and Telegram displays the caption anyway.
        safe_name = filename.encode("ascii", "ignore").decode() or asset_id
        files.append((attach_name, safe_name, ctype, data))

    fields = {"chat_id": str(chat_id), "media": json.dumps(media)}
    body, content_type = build_multipart(fields, files)
    status, _, resp = http(
        f"https://api.telegram.org/bot{token}/sendMediaGroup",
        method="POST",
        headers={"Content-Type": content_type, "Content-Length": str(len(body))},
        data=body,
    )
    if status != 200:
        sys.exit(f"Telegram sendMediaGroup -> HTTP {status}: {resp[:300]!r}")


def send_memory_album(token, chat_id, mem, public_url, api_key, internal_url,
                      attach_per_memory, header, dry_run):
    """Send one memory as an album (or as caption-only text if no thumbnails)."""
    caption = album_caption(mem, public_url, header)
    images = [a for a in mem["assets"] if a.get("type") == "IMAGE"][:attach_per_memory]

    if dry_run:
        print(f"--- album for memory {mem['id']} ---")
        print(caption)
        for a in images:
            print(f"  attach: {a.get('originalFileName') or a['id']}  (asset {a['id']})")
        if not images:
            print("  (no IMAGE assets — would send caption-only message)")
        print()
        return

    photos = []
    for a in images:
        result = fetch_preview(internal_url, api_key, a["id"])
        if result is None:
            continue
        data, ctype = result
        photos.append((a["id"], a.get("originalFileName") or a["id"], ctype, data))

    if photos:
        send_media_group(token, chat_id, caption, photos)
    else:
        send_telegram(token, chat_id, caption)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be sent, do not fetch thumbnails or POST")
    ap.add_argument("--top", type=int, default=3,
                    help="cap to top N memories by asset count (default 3)")
    ap.add_argument("--asset-preview", type=int, default=2,
                    help="--no-attach mode: first N asset filenames per memory (default 2)")
    ap.add_argument("--attach-per-memory", type=int, default=4,
                    help="attach mode: up to N photos per album, capped at 10 by Telegram (default 4)")
    ap.add_argument("--no-attach", action="store_true",
                    help="send a single text-only summary instead of per-memory albums")
    args = ap.parse_args()

    api_key = os.environ.get("IMMICH_API_KEY")
    if not api_key:
        sys.exit("IMMICH_API_KEY env var is required")

    internal = os.environ.get("IMMICH_INTERNAL_URL", "http://127.0.0.1:2283").rstrip("/")
    public = os.environ.get("IMMICH_PUBLIC_URL", "https://rpi5.gate-mintaka.ts.net:10000").rstrip("/")

    memories = fetch_memories(internal, api_key)
    today = select_today(memories, datetime.now(timezone.utc))
    if not today or args.top <= 0:
        return 0

    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID")
    if not args.dry_run and (not token or not chat_id):
        sys.exit("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID env vars are required (unless --dry-run)")

    total = len(today)
    memories_sorted = sorted(today, key=lambda m: len(m["assets"]), reverse=True)
    shown = memories_sorted[:args.top]

    if args.no_attach:
        text = format_message(today, public, args.top, args.asset_preview)
        if args.dry_run:
            sys.stdout.write(text)
            return 0
        send_telegram(token, chat_id, text)
        return 0

    attach_cap = max(1, min(args.attach_per_memory, 10))
    header = f"📸 <b>Immich on this day</b>\n<i>{total} memor{'y' if total == 1 else 'ies'} today</i>\n\n"

    for i, mem in enumerate(shown):
        send_memory_album(
            token, chat_id, mem, public, api_key, internal,
            attach_cap, header if i == 0 else "", args.dry_run,
        )

    if total > args.top:
        tail = f"<i>+ {total - args.top} more memor{'y' if total - args.top == 1 else 'ies'}</i>"
        if args.dry_run:
            print(tail)
        else:
            send_telegram(token, chat_id, tail)

    return 0


if __name__ == "__main__":
    sys.exit(main())
