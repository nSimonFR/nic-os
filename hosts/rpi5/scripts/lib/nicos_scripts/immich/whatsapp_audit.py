#!/usr/bin/env python3
"""
immich-whatsapp-audit: weekly guard on the workflow that archives WhatsApp images.

The workflow archives every upload whose filename is a bare UUID. Three checks:

  * integrity — the workflow is enabled and its two steps are intact, in order.
    Step order follows `plugin_method`'s physical row order (ctid), which an
    upgrade can reshuffle. On any drift the workflow is disabled first, then
    reported: a broken filter would archive the whole library.
  * false positives — archived this window, UUID-named, not in the WhatsApp
    album, but in a curated album or shot on a real camera / someone's iPhone 16.
  * volume — this week >= max(20, 3x the trailing 8-week median).

Silent when all is well. A failure exits 1, which systemd-failed-alert reports.

Env: IMMICH_URL, IMMICH_API_KEY_FILE, IMMICH_DB, AUDIT_WINDOW_DAYS, TELEGRAM_SEND.
"""

import json
import statistics
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass

from ..logs import logger
from ..secrets import env_int, env_str, read_secret

log = logger("immich-whatsapp-audit", lambda: sys.stderr)

WORKFLOW = "ef9b3c99-b034-42ed-a98b-484926266385"
WHATSAPP_ALBUM = "e5a36785-5742-43f5-81ab-28f4ffd18c4e"
PUBLIC = "https://rpi5.gate-mintaka.ts.net:10000/photos/"
UUID_REGEX = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\."
STEPS = ["assetFileFilter", "assetArchive"]
FILTER_CONFIG = {"pattern": UUID_REGEX, "matchType": "regex", "caseSensitive": False}
AUTO_ALBUMS = ("Recents", "Recently Saved")
REAL_CAMERAS = ("SONY", "NIKON", "FUJIFILM", "CANON", "SCANNER")


@dataclass(frozen=True)
class Config:
    immich_url: str = "http://127.0.0.1:2283"
    key_file: str = "/run/agenix/immich-clip-api-key"
    db: str = "immich"
    window_days: int = 7
    telegram_send: str = "telegram-send"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            immich_url=env_str("IMMICH_URL", cls.immich_url, env).rstrip("/"),
            key_file=env_str("IMMICH_API_KEY_FILE", cls.key_file, env),
            db=env_str("IMMICH_DB", cls.db, env),
            window_days=env_int("AUDIT_WINDOW_DAYS", cls.window_days, env),
            telegram_send=env_str("TELEGRAM_SEND", cls.telegram_send, env),
        )


def _run(argv, stdin_text=None):
    p = subprocess.run(argv, input=stdin_text, capture_output=True, text=True, timeout=120)
    if p.returncode:
        raise RuntimeError(f"{argv[0]} exited {p.returncode}: {p.stderr.strip()}")
    return p.stdout


def psql(run, db, sql):
    """Peer auth over the local socket: the unit runs as `immich`, the DB owner."""
    return run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-d", db, "-c", sql]).strip()


def json_rows(run, db, sql):
    out = psql(run, db, f"SELECT row_to_json(x) FROM ({sql}) x;")
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def integrity(run, db):
    order = psql(run, db, "SELECT name FROM plugin_method WHERE name IN "
                 "('assetFileFilter','assetArchive') ORDER BY ctid;").splitlines()
    wf = json_rows(run, db, f"SELECT enabled, name FROM workflow WHERE id='{WORKFLOW}'")
    steps = json_rows(run, db, f"""
      SELECT pm.name, ws.enabled, ws.config
      FROM workflow_step ws JOIN plugin_method pm ON pm.id = ws."pluginMethodId"
      WHERE ws."workflowId" = '{WORKFLOW}' ORDER BY ws.ctid""")
    return order, wf, steps


def is_incident(order, wf, steps):
    return (
        order != STEPS
        or len(wf) != 1
        or not wf[0].get("enabled")
        or [s.get("name") for s in steps] != STEPS
        or not all(s.get("enabled") for s in steps)
        or steps[0].get("config") != FILTER_CONFIG
        or steps[1].get("config") != {}
    )


def disable_workflow(cfg, key, opener=None):
    """None on success, else the error text — the alert must say which."""
    req = urllib.request.Request(
        f"{cfg.immich_url}/api/workflows/{WORKFLOW}",
        data=b'{"enabled":false}',
        method="PUT",
        headers={"x-api-key": key, "Content-Type": "application/json"},
    )
    try:
        with (opener or urllib.request.urlopen)(req, timeout=20) as resp:
            return None if 200 <= resp.status < 300 else f"HTTP {resp.status}"
    except (urllib.error.URLError, OSError) as e:
        return str(e)


def candidates(run, cfg):
    return json_rows(run, cfg.db, f"""
      SELECT a.id, a."originalFileName", a."createdAt", e.make, e.model,
             COALESCE(array_agg(DISTINCT al."albumName")
                      FILTER (WHERE al.id IS NOT NULL), ARRAY[]::varchar[]) AS albums,
             COALESCE(bool_or(aa."albumId" = '{WHATSAPP_ALBUM}'), false) AS in_whatsapp
      FROM asset a
      LEFT JOIN asset_exif e ON e."assetId" = a.id
      LEFT JOIN album_asset aa ON aa."assetId" = a.id
      LEFT JOIN album al ON al.id = aa."albumId" AND al."deletedAt" IS NULL
      WHERE a.visibility = 'archive'
        AND a."createdAt" >= now() - make_interval(days => {int(cfg.window_days)})
        AND a."originalFileName" ~ '{UUID_REGEX}'
      GROUP BY a.id, a."originalFileName", a."createdAt", e.make, e.model
      ORDER BY a."createdAt" DESC""")


def reportable(assets):
    out = []
    for a in assets:
        if a.get("in_whatsapp"):
            continue
        albums = a.get("albums") or []
        curated = [x for x in albums if x not in AUTO_ALBUMS and not x.startswith("[AUTO]")]
        camera = " ".join(x for x in (a.get("make"), a.get("model")) if x).strip() or "no EXIF"
        reasons = (
            (["curated album"] if curated else [])
            + (["non-phone camera"] if any(c in camera.upper() for c in REAL_CAMERAS) else [])
            + (["iPhone 16 family"] if "IPHONE 16" in camera.upper() else [])
        )
        if reasons:
            out.append({**a, "curated": curated, "camera": camera, "reason": ", ".join(reasons)})
    return out


def weekly_volumes(run, db):
    """Archived count per ISO week, current week first, then 8 completed weeks."""
    rows = json_rows(run, db, """
      WITH weeks AS (
        SELECT date_trunc('week', now()) - n * interval '1 week' AS wk
        FROM generate_series(0, 8) AS n)
      SELECT wk::date AS week, count(a.id)::int AS archived
      FROM weeks w LEFT JOIN asset a ON a.visibility = 'archive'
        AND a."createdAt" >= w.wk AND a."createdAt" < w.wk + interval '1 week'
      GROUP BY wk ORDER BY wk DESC""")
    return [r["archived"] for r in rows]


def spike(volumes):
    """(this_week, median) when this week is a spike, else None."""
    if not volumes:
        return None
    this_week, trailing = volumes[0], volumes[1:]
    median = int(statistics.median_low(trailing)) if trailing else 0
    return (this_week, median) if this_week >= max(20, median * 3) else None


def _esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def incident_message(order, wf, steps, error, archived_recently):
    status = "disabled" if error is None else f"DISABLE FAILED ({_esc(error)})"
    return (
        "🔴 <b>Immich WhatsApp archive incident</b>\n"
        f"Workflow {status}.\n"
        f"order={_esc(order)}; workflow={_esc(wf)}; steps={_esc(steps)}\n"
        f"Archived in the last 7 days: {archived_recently}"
    )


def audit_message(flagged, spiked):
    lines = ["⚠️ <b>Immich WhatsApp archive audit</b>"]
    if flagged:
        lines.append(f"Possible false positives: {len(flagged)}")
        for a in flagged[:20]:
            albums = ", ".join(a["curated"] or a.get("albums") or ["none"])
            lines.append(
                f'• <a href="{PUBLIC}{a["id"]}">{_esc(a["originalFileName"])}</a> — '
                f'{a["createdAt"][:10]}; {_esc(albums)}; {_esc(a["camera"])} ({a["reason"]})'
            )
    if spiked:
        lines.append(f"Archive volume spike: {spiked[0]} this week; "
                     f"trailing 8-week median {spiked[1]}.")
    return "\n".join(lines)


def send(cfg, html, run):
    """telegram-send always exits 0, so success is read off the API reply."""
    out = run([cfg.telegram_send, "-m", "html"], html)
    if '"ok":true' not in out.replace(" ", ""):
        raise RuntimeError(f"Telegram rejected the message: {out.strip()}")


def run_audit(cfg, run=_run, opener=None, key=None):
    """The message sent, or "" when silent."""
    order, wf, steps = integrity(run, cfg.db)
    if is_incident(order, wf, steps):
        error = disable_workflow(cfg, key or read_secret(cfg.key_file), opener=opener)
        recent = psql(run, cfg.db, "SELECT count(*) FROM asset WHERE visibility='archive' "
                      "AND \"createdAt\" >= now() - interval '7 days';")
        message = incident_message(order, wf, steps, error, recent)
    else:
        flagged = reportable(candidates(run, cfg))
        spiked = spike(weekly_volumes(run, cfg.db))
        if not flagged and not spiked:
            log("workflow intact, no false positives, no spike — silent")
            return ""
        message = audit_message(flagged, spiked)
    send(cfg, message, run)
    return message


def main(argv=None, env=None):
    del argv
    try:
        run_audit(Config.from_env(env))
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        log(f"FATAL: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
