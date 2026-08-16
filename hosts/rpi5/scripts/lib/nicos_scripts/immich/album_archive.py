#!/usr/bin/env python3
"""Keep the timeline clear of media that arrived through another app.

The problem this solves is "WhatsApp photos flood my Immich timeline". The
earlier attempt guessed at it from EXIF — `make != Apple`, missing timezone —
and got it wrong in both directions, because WhatsApp strips metadata and so do
plenty of legitimate cameras. That approach was built and reverted.

This one uses provenance instead of a guess. WhatsApp's "Save to Camera Roll"
writes into an iOS album named `WhatsApp`; the Immich mobile app mirrors device
album membership onto the server. So a photo is in that album if and only if
WhatsApp put it there. No threshold to tune and no false positives available.

Why a timer and not a workflow: Immich workflows trigger on `AssetCreate` /
`AssetMetadataExtraction` only. Album membership is written *after* upload (and,
for a back-fill, long after), so there is no event to hang this off — it has to
be reconciled on a schedule.

Idempotent by construction: the query asks Immich for assets in the album that
are *still* `timeline`, so a run with nothing new does no writes at all. It
never un-archives, and it never touches `hidden`.

`IMMICH_ARCHIVE_ONLY_IF_AWAKE` is the part that stops this being a nuisance.
Immich is socket-activated with a 30-minute idle sleep (immich.nix), so a plain
timer would poke it awake around the clock and undo that. Gating on the unit
already being active costs nothing, because the gate is not merely an
optimisation: album membership is only ever written by an upload, an upload
wakes Immich, so an Immich that never wakes has nothing new to sweep. Worst case
is a photo landing just before the idle timeout with no tick left in the window
— it gets swept on the next wake instead.

Config via environment:
  IMMICH_URL                    base url             (default http://127.0.0.1:2283)
  IMMICH_API_KEY_FILE           agenix secret path   (default /run/agenix/immich-api-key)
  IMMICH_ARCHIVE_ALBUMS         comma-separated      (default WhatsApp)
  IMMICH_ARCHIVE_APPLY          "1" to actually write (default off — dry run)
  IMMICH_ARCHIVE_ONLY_IF_AWAKE  unit to gate on      (default none — always run)
"""

import json
import subprocess
import sys
import urllib.request
from dataclasses import dataclass

from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_str, read_secret_env

DEFAULT_URL = "http://127.0.0.1:2283"
DEFAULT_KEY_FILE = "/run/agenix/immich-api-key"
DEFAULT_ALBUMS = "WhatsApp"

PAGE_SIZE = 1000
CHUNK = 400  # ids per PUT; the whole album back-fill went through at this size
TIMEOUT = 60

log = logger("immich-album-archive")


class ImmichUnreachable(Exception):
    """Immich did not answer. Nothing was written; the next run retries."""


@dataclass(frozen=True)
class Config:
    url: str = DEFAULT_URL
    key_file: str = DEFAULT_KEY_FILE
    albums: tuple = (DEFAULT_ALBUMS,)
    # Dry run is the default so a Config built with no environment cannot flip
    # anyone's visibility. The unit opts in explicitly.
    apply: bool = False
    only_if_awake: str = ""

    @classmethod
    def from_env(cls, env=None):
        names = tuple(
            n.strip()
            for n in env_str("IMMICH_ARCHIVE_ALBUMS", DEFAULT_ALBUMS, env).split(",")
            if n.strip()
        )
        return cls(
            url=env_str("IMMICH_URL", DEFAULT_URL, env).rstrip("/"),
            key_file=env_str("IMMICH_API_KEY_FILE", DEFAULT_KEY_FILE, env),
            albums=names,
            apply=env_str("IMMICH_ARCHIVE_APPLY", "", env).strip() in ("1", "true", "yes"),
            only_if_awake=env_str("IMMICH_ARCHIVE_ONLY_IF_AWAKE", "", env).strip(),
        )


def is_awake(unit, run=None):
    """Is `unit` active right now? Unset unit -> always yes.

    Deliberately does NOT use the API: any request to :2283 goes through the
    socket-activate proxy and would wake the very service we are asking about.
    """
    if not unit:
        return True
    runner = run or subprocess.run
    try:
        proc = runner(["systemctl", "is-active", "--quiet", unit], check=False)
    except OSError:
        return True  # no systemctl (tests, a container) — don't silently do nothing
    return proc.returncode == 0


def _headers(key):
    return {"x-api-key": key, "Content-Type": "application/json"}


def album_ids(cfg, key, opener=None):
    """Resolve configured album names to ids. -> {name: id} for those that exist.

    Resolved by name on every run, deliberately: the mobile app recreates these
    albums with a fresh uuid whenever the device-side sync is redone, so a
    hard-coded id would silently stop matching.
    """
    albums = get_json(f"{cfg.url}/api/albums", _headers(key), TIMEOUT, opener)
    by_name = {a["albumName"]: a["id"] for a in albums}
    return {n: by_name[n] for n in cfg.albums if n in by_name}


def timeline_assets(cfg, key, album_id, opener=None):
    """Every asset in the album that is still on the timeline. -> [asset dict].

    `visibility` is part of the query, not a post-filter: on a steady-state run
    this comes back empty and the whole thing is one cheap request.
    """
    out, page = [], 1
    while page:
        body = json.dumps({
            "albumIds": [album_id],
            "visibility": "timeline",
            "size": PAGE_SIZE,
            "page": page,
        }).encode()
        req = urllib.request.Request(
            f"{cfg.url}/api/search/metadata", data=body,
            headers=_headers(key), method="POST")
        assets = http_json(req, TIMEOUT, opener).get("assets", {})
        out.extend(assets.get("items", []))
        nxt = assets.get("nextPage")
        page = int(nxt) if nxt else None
    return out


def archivable(assets):
    """Drop the ones an explicit human signal says to leave alone. -> [id].

    A favourite is exactly that signal: the photo may well have come through
    WhatsApp, but it has been marked worth keeping in front of you, and hiding
    it from the timeline is the opposite of what that meant.
    """
    return [a["id"] for a in assets if not a.get("isFavorite")]


def archive(cfg, key, ids, opener=None):
    """PUT the visibility flip in chunks. -> count written."""
    for i in range(0, len(ids), CHUNK):
        body = json.dumps({"ids": ids[i:i + CHUNK], "visibility": "archive"}).encode()
        req = urllib.request.Request(
            f"{cfg.url}/api/assets", data=body, headers=_headers(key), method="PUT")
        http_json(req, TIMEOUT, opener)
    return len(ids)


def sweep(cfg, key, opener=None, log=log):
    """Archive new timeline arrivals in every configured album. -> count."""
    try:
        found = album_ids(cfg, key, opener)
    except Exception as e:  # noqa: BLE001 - any failure here is "Immich is away"
        raise ImmichUnreachable(str(e)[:120]) from e

    for missing in [n for n in cfg.albums if n not in found]:
        # Not fatal: the mobile app drops and recreates these albums, so an
        # absent one usually means a sync is mid-flight, not a misconfiguration.
        log(f"album {missing!r} not found — skipping")

    total = 0
    for name, aid in found.items():
        try:
            assets = timeline_assets(cfg, key, aid, opener)
        except Exception as e:  # noqa: BLE001
            raise ImmichUnreachable(str(e)[:120]) from e
        ids = archivable(assets)
        skipped = len(assets) - len(ids)
        if not ids:
            log(f"{name}: nothing new" + (f" ({skipped} favourite(s) left alone)" if skipped else ""))
            continue
        if not cfg.apply:
            log(f"{name}: DRY RUN, would archive {len(ids)} asset(s)")
            continue
        try:
            total += archive(cfg, key, ids, opener)
        except Exception as e:  # noqa: BLE001
            raise ImmichUnreachable(str(e)[:120]) from e
        log(f"{name}: archived {len(ids)}" + (f", left {skipped} favourite(s)" if skipped else ""))
    return total


def main(env=None, opener=None, log=log, run=None):
    cfg = Config.from_env(env)
    if not is_awake(cfg.only_if_awake, run):
        log(f"{cfg.only_if_awake} asleep — nothing can have been uploaded; skipping")
        return 0
    key = read_secret_env("IMMICH_API_KEY_FILE", cfg.key_file, env)
    if not key:
        log(f"FATAL: no api key readable at {cfg.key_file}")
        return 1
    try:
        n = sweep(cfg, key, opener, log)
    except ImmichUnreachable as e:
        log(f"ABORT: immich unreachable ({e}); retrying next run")
        return 75  # EX_TEMPFAIL
    log(f"DONE archived {n} asset(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
