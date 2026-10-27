#!/usr/bin/env python3
"""
hermes-whatsapp-audit: weekly guard on the Immich workflow that archives
WhatsApp (bare-UUID-named) uploads.

  * integrity — the workflow is enabled and runs filter-then-archive with the
    expected config. On any drift it is disabled first, then reported: a filter
    that stops filtering archives the whole library.
  * false positives — archived this window, UUID-named, not in the WhatsApp album,
    but in a curated album or shot on a real camera / someone's iPhone 16.
  * volume — this week >= max(20, 3x the trailing 8-week median).

Immich goes through Agent Vault (`immich.home.arpa`, placeholder key). Output is
the message; empty means all is well.

Env: IMMICH_{URL,API_KEY}, AUDIT_WINDOW_DAYS.
"""

import json
import re
import statistics
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_int, env_str

log = logger("hermes-whatsapp-audit", lambda: sys.stderr)

DEFAULT_IMMICH = "http://immich.home.arpa:2283"
PLACEHOLDER_KEY = "__immich_api_key__"
WORKFLOW = "ef9b3c99-b034-42ed-a98b-484926266385"
WHATSAPP_ALBUM = "e5a36785-5742-43f5-81ab-28f4ffd18c4e"
PUBLIC = "https://rpi5.gate-mintaka.ts.net:10000/photos/"
UUID_REGEX = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\."
STEPS = ["immich-plugin-core#assetFileFilter", "immich-plugin-core#assetArchive"]
FILTER_CONFIG = {"pattern": UUID_REGEX, "matchType": "regex", "caseSensitive": False}
AUTO_ALBUMS = ("Recents", "Recently Saved")
REAL_CAMERAS = ("SONY", "NIKON", "FUJIFILM", "CANON", "SCANNER")


@dataclass(frozen=True)
class Config:
    immich_url: str = DEFAULT_IMMICH
    api_key: str = PLACEHOLDER_KEY
    window_days: int = 7

    @classmethod
    def from_env(cls, env=None):
        return cls(
            immich_url=env_str("IMMICH_URL", DEFAULT_IMMICH, env).rstrip("/"),
            api_key=env_str("IMMICH_API_KEY", "", env) or PLACEHOLDER_KEY,
            window_days=env_int("AUDIT_WINDOW_DAYS", 7, env),
        )


def _headers(cfg):
    return {"x-api-key": cfg.api_key, "Content-Type": "application/json"}


def _post(cfg, path, payload, opener=None):
    req = urllib.request.Request(
        f"{cfg.immich_url}/api{path}", data=json.dumps(payload).encode(),
        headers=_headers(cfg), method="POST",
    )
    return http_json(req, timeout=60, opener=opener)


def is_incident(wf):
    steps = wf.get("steps") or []
    return (
        not wf.get("enabled")
        or [s.get("method") for s in steps] != STEPS
        or not all(s.get("enabled") for s in steps)
        or steps[0].get("config") != FILTER_CONFIG
        or steps[1].get("config") != {}
    )


def disable_workflow(cfg, opener=None):
    """None on success, else the error text — the alert must say which."""
    req = urllib.request.Request(
        f"{cfg.immich_url}/api/workflows/{WORKFLOW}", data=b'{"enabled":false}',
        headers=_headers(cfg), method="PUT",
    )
    try:
        with (opener or urllib.request.urlopen)(req, timeout=20) as resp:
            return None if 200 <= resp.status < 300 else f"HTTP {resp.status}"
    except (urllib.error.URLError, OSError) as e:
        return str(e)


def archived_count(cfg, after, before=None, opener=None):
    payload = {"visibility": "archive", "createdAfter": after.isoformat()}
    if before:
        payload["createdBefore"] = before.isoformat()
    return int(_post(cfg, "/search/statistics", payload, opener=opener).get("total", 0))


def uuid_archives(cfg, since, opener=None):
    """UUID-named archives created since `since`, every page."""
    out, page = [], 1
    while page:
        d = _post(cfg, "/search/metadata", {
            "visibility": "archive", "createdAfter": since.isoformat(),
            "withExif": True, "size": 1000, "page": page,
        }, opener=opener)["assets"]
        out += [a for a in d.get("items") or []
                if re.match(UUID_REGEX, a.get("originalFileName") or "")]
        page = int(d["nextPage"]) if d.get("nextPage") else None
    return out


def classify(asset, albums):
    """The reasons `asset` looks like a false positive; [] when it does not."""
    if any(a.get("id") == WHATSAPP_ALBUM for a in albums):
        return []
    names = [a.get("albumName") or "" for a in albums]
    curated = [n for n in names if n not in AUTO_ALBUMS and not n.startswith("[AUTO]")]
    exif = asset.get("exifInfo") or {}
    camera = " ".join(x for x in (exif.get("make"), exif.get("model")) if x).upper()
    return (
        (["curated album: " + ", ".join(curated)] if curated else [])
        + (["non-phone camera"] if any(c in camera for c in REAL_CAMERAS) else [])
        + (["iPhone 16 family"] if "IPHONE 16" in camera else [])
    )


def false_positives(cfg, since, opener=None):
    flagged = []
    for asset in uuid_archives(cfg, since, opener=opener):
        albums = get_json(f"{cfg.immich_url}/api/albums?assetId={asset['id']}",
                          _headers(cfg), opener=opener)
        if reasons := classify(asset, albums):
            flagged.append((asset, reasons))
    return flagged


def weekly_volumes(cfg, now, opener=None):
    """Archived per UTC week, current (partial) week first, then 8 completed."""
    monday = (now - timedelta(days=now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0)
    out = [archived_count(cfg, monday, opener=opener)]
    for n in range(1, 9):
        start = monday - timedelta(weeks=n)
        out.append(archived_count(cfg, start, start + timedelta(weeks=1), opener=opener))
    return out


def spike(volumes):
    """(this_week, median) when this week is a spike, else None."""
    this_week, trailing = volumes[0], volumes[1:]
    median = int(statistics.median_low(trailing)) if trailing else 0
    return (this_week, median) if this_week >= max(20, median * 3) else None


def run(cfg, now=None, opener=None):
    """The message to print — "" means stay silent."""
    now = now or datetime.now(timezone.utc)
    wf = get_json(f"{cfg.immich_url}/api/workflows/{WORKFLOW}", _headers(cfg), opener=opener)
    if is_incident(wf):
        error = disable_workflow(cfg, opener=opener)
        status = "disabled" if error is None else f"DISABLE FAILED ({error})"
        steps = [(s.get("method"), s.get("enabled"), s.get("config"))
                 for s in wf.get("steps") or []]
        return "\n".join([
            "🔴 Immich WhatsApp archive incident",
            f"Workflow {status}.",
            f"enabled={wf.get('enabled')}; steps={steps}",
            f"Archived in the last 7 days: "
            f"{archived_count(cfg, now - timedelta(days=7), opener=opener)}",
        ])

    flagged = false_positives(cfg, now - timedelta(days=cfg.window_days), opener=opener)
    spiked = spike(weekly_volumes(cfg, now, opener=opener))
    if not flagged and not spiked:
        log("workflow intact, no false positives, no spike — silent")
        return ""

    lines = ["⚠️ Immich WhatsApp archive audit"]
    if flagged:
        lines.append(f"Possible false positives: {len(flagged)}")
        for asset, reasons in flagged[:20]:
            lines.append(f"• {asset['originalFileName']} — {asset['createdAt'][:10]}; "
                         f"{'; '.join(reasons)}\n  {PUBLIC}{asset['id']}")
    if spiked:
        lines.append(f"Archive volume spike: {spiked[0]} this week; "
                     f"trailing 8-week median {spiked[1]}.")
    return "\n".join(lines)


def main(argv=None, env=None):
    del argv
    try:
        message = run(Config.from_env(env))
    except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError) as e:
        log(f"FATAL: {e}")
        return 1
    if message:
        print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main())
