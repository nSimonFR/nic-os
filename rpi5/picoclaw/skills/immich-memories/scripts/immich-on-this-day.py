#!/usr/bin/env python3
"""Print today's Immich on-this-day memories as a human-readable summary.

Picoclaw owns transport (it relays the output to Telegram); this skill just
queries Immich. Exits 0 with empty stdout when today has no memories.

Config (env):
  IMMICH_API_KEY        required  (/run/agenix/immich-api-key)
  IMMICH_INTERNAL_URL   default http://127.0.0.1:2283
  IMMICH_PUBLIC_URL     default https://rpi5.gate-mintaka.ts.net:10000
"""
import argparse
import json
import os
import sys
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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--top", type=int, default=3,
                    help="cap to top N memories by asset count (default 3)")
    ap.add_argument("--asset-preview", type=int, default=2,
                    help="text mode: first N asset filenames listed per memory (default 2)")
    ap.add_argument("--json", action="store_true",
                    help="emit structured JSON instead of human-readable text")
    args = ap.parse_args()

    api_key = os.environ.get("IMMICH_API_KEY")
    if not api_key:
        sys.exit("IMMICH_API_KEY env var is required")

    internal = os.environ.get("IMMICH_INTERNAL_URL", "http://127.0.0.1:2283").rstrip("/")
    public = os.environ.get("IMMICH_PUBLIC_URL", "https://rpi5.gate-mintaka.ts.net:10000").rstrip("/")

    memories = fetch_memories(internal, api_key)
    today = select_today(memories, datetime.now(timezone.utc))

    if args.json:
        print(json.dumps(format_json(today, public, max(0, args.top)), indent=2))
        return 0

    if not today or args.top <= 0:
        return 0

    sys.stdout.write(format_text(today, public, args.top, args.asset_preview))
    return 0


if __name__ == "__main__":
    sys.exit(main())
