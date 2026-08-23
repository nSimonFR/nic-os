#!/usr/bin/env python3
"""Adopt someone else's photos into my own library, so they stop being theirs.

An Immich asset has exactly one owner, and album sharing does not change that.
Adding an asset to any album needs `Permission.AssetShare`, which resolves to
**owner OR partner** and nothing else (server `utils/access.js`) — being an album
`editor` is not enough. So a photo a friend put in a shared album cannot be put
in a *different* album of mine, and does not show in my timeline.

Two ways out, solving different problems:

  * Partner sharing — the sharer grants their whole library, `AssetShare` then
    passes, zero duplication. But the assets stay theirs: their quota, and they
    vanish from my albums if they delete them or leave. Needs no script.
  * This script — download the original and re-upload it as me. I own the copy,
    so it survives all of that. Costs a second copy on disk.

Two source modes:

  --source ALBUM      adopt the assets in an album that are not already mine.
                      The one-off case (a friend, 19 photos, no reason to ask
                      for their whole library).
  --from-owner USER   adopt everything a given user owns. The continuous case:
                      point it at a partner and run it on a timer, and their
                      uploads keep landing in my library as *my* copies.

Live Photos are the wrinkle: the motion video is a *separate* hidden asset, so it
is uploaded first and the still is then linked to it via `livePhotoVideoId` —
miss that and the copies are silently no longer alive. Enumeration therefore only
ever walks `visibility=timeline`; motion halves arrive through their still, never
on their own.

Re-running is safe twice over. The server rejects a second upload of the same
checksum for the same owner and hands back the existing id (`status: duplicate`),
and the state file means an already-adopted asset is not even re-downloaded. Every
run still re-asserts album membership for known copies, so a copy removed from the
album by hand comes back rather than being silently forgotten.

Config via environment (each overridable by the matching flag):
  IMMICH_URL              base url            (default http://127.0.0.1:2283)
  IMMICH_API_KEY_FILE     agenix secret path  (default /run/agenix/immich-api-key)
  IMMICH_ADOPT_SOURCE     album id to adopt *from*
  IMMICH_ADOPT_OWNER      user id to adopt *everything* from (alternative source)
  IMMICH_ADOPT_TARGET     album id for my copies (default: the source album)
  IMMICH_ADOPT_STATE      json cursor path    (default /var/lib/immich-adopt/state.json)
  IMMICH_ADOPT_DRY_RUN    "0" to actually write       (default dry run)
  IMMICH_ADOPT_REPLACE    "1" to drop the original's album entry afterwards

`--replace` is the only destructive-to-the-sharer flag and is off by default: it
removes *their* album entry (their photo stays in their library, but their
comments on it and their contributor credit go with the entry). It also only works
on albums I own — on someone else's album the server falls back to a per-asset
`AssetShare` check and refuses, which is a permission error, not a bug.
"""

import argparse
import json
import mimetypes
import sys
import urllib.request
import uuid
from dataclasses import dataclass, replace as _replace

from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_str, read_secret_env
from ..state import ensure_dir, load_json, save_json

DEFAULT_URL = "http://127.0.0.1:2283"
DEFAULT_KEY_FILE = "/run/agenix/immich-api-key"
DEFAULT_STATE = "/var/lib/immich-adopt/state.json"

# The server pages metadata search; 1000 is its documented ceiling per page.
PAGE_SIZE = 1000
# Originals are multi-MB and the Pi is not fast. Generous, but still bounded.
TRANSFER_TIMEOUT = 300

log = logger("immich-adopt")


class AdoptError(Exception):
    """Config or permission problem that should stop the run, loudly."""


@dataclass(frozen=True)
class Config:
    url: str = DEFAULT_URL
    key: str = ""
    source: str = ""
    owner: str = ""
    target: str = ""
    state_path: str = DEFAULT_STATE
    # Both default to the SAFE value, so a Config built from an empty env
    # cannot write anything and cannot touch the sharer's album entries.
    dry_run: bool = True
    replace: bool = False

    @classmethod
    def from_env(cls, env=None):
        return cls(
            url=env_str("IMMICH_URL", DEFAULT_URL, env).rstrip("/"),
            key=read_secret_env("IMMICH_API_KEY_FILE", DEFAULT_KEY_FILE, env) or "",
            source=env_str("IMMICH_ADOPT_SOURCE", "", env),
            owner=env_str("IMMICH_ADOPT_OWNER", "", env),
            target=env_str("IMMICH_ADOPT_TARGET", "", env),
            state_path=env_str("IMMICH_ADOPT_STATE", DEFAULT_STATE, env),
            dry_run=env_str("IMMICH_ADOPT_DRY_RUN", "1", env) != "0",
            replace=env_str("IMMICH_ADOPT_REPLACE", "0", env) == "1",
        )

    @property
    def target_album(self):
        """Where my copies land. Defaults to the album they came from."""
        return self.target or self.source


def _headers(cfg, extra=None):
    h = {"x-api-key": cfg.key, "Accept": "application/json"}
    h.update(extra or {})
    return h


def _post_json(cfg, path, payload, method="POST", opener=None):
    req = urllib.request.Request(
        f"{cfg.url}{path}",
        data=json.dumps(payload).encode(),
        headers=_headers(cfg, {"Content-Type": "application/json"}),
        method=method,
    )
    return http_json(req, timeout=60, opener=opener)


def whoami(cfg, opener=None):
    return get_json(f"{cfg.url}/api/users/me", headers=_headers(cfg), opener=opener)["id"]


def album(cfg, album_id, opener=None):
    return get_json(
        f"{cfg.url}/api/albums/{album_id}?withoutAssets=true",
        headers=_headers(cfg),
        opener=opener,
    )


def asset(cfg, asset_id, opener=None):
    return get_json(
        f"{cfg.url}/api/assets/{asset_id}", headers=_headers(cfg), opener=opener
    )


def album_assets(cfg, album_id, opener=None):
    """Every asset in an album, following the server's `nextPage` cursor.

    v3 dropped the embedded `assets` array from `GET /api/albums/:id`, so this
    goes through metadata search — which is also the only shape that reports
    `livePhotoVideoId`, the field the whole Live Photo path depends on.
    """
    out, page = [], 1
    while page:
        body = {"albumIds": [album_id], "size": PAGE_SIZE, "page": page}
        found = _post_json(cfg, "/api/search/metadata", body, opener=opener)["assets"]
        out.extend(found["items"])
        nxt = found.get("nextPage")
        page = int(nxt) if nxt else None
    return out


def owner_assets(cfg, owner_id, opener=None):
    """Every timeline asset a given user owns, via the month-bucket timeline.

    Metadata search has no owner filter in v3, but the timeline does (`userId`),
    and it is the only endpoint that will enumerate a *partner's* library. The
    payload is columnar (parallel arrays, not a list of objects) and omits
    `fileModifiedAt`/`originalFileName`, so what comes back here is a stub that
    `_detailed` fills in — only for the assets actually being adopted, which is
    what keeps a timer run cheap once the backlog is done.
    """
    out = []
    listed = get_json(
        f"{cfg.url}/api/timeline/buckets?userId={owner_id}&visibility=timeline",
        headers=_headers(cfg),
        opener=opener,
    )
    for bucket in listed:
        cols = get_json(
            f"{cfg.url}/api/timeline/bucket?userId={owner_id}"
            f"&visibility=timeline&timeBucket={bucket['timeBucket']}",
            headers=_headers(cfg),
            opener=opener,
        )
        ids = cols.get("id") or []
        for i, asset_id in enumerate(ids):
            out.append({
                "id": asset_id,
                "ownerId": _col(cols, "ownerId", i, owner_id),
                "livePhotoVideoId": _col(cols, "livePhotoVideoId", i),
                # Deliberately no fileModifiedAt/originalFileName: absence is the
                # signal to `_detailed` that this stub needs a round trip.
            })
    return out


def _col(cols, name, i, default=None):
    """One cell out of the timeline's columnar payload."""
    values = cols.get(name)
    if not values or i >= len(values):
        return default
    return values[i]


def _detailed(cfg, src, opener=None):
    """Fill in a timeline stub. A metadata-search result is already complete."""
    if "fileModifiedAt" in src:
        return src
    return asset(cfg, src["id"], opener=opener)


def download_original(cfg, asset_id, opener=None):
    """Raw bytes of the original file. Not JSON, hence not `get_json`."""
    req = urllib.request.Request(
        f"{cfg.url}/api/assets/{asset_id}/original", headers=_headers(cfg)
    )
    with (opener or urllib.request.urlopen)(req, timeout=TRANSFER_TIMEOUT) as resp:
        return resp.read()


def _multipart(fields, filename, data):
    """Encode one file plus text fields as multipart/form-data.

    Hand-rolled because this package is stdlib-only by policy, and because the
    upload endpoint wants the file under the exact field name `assetData`.
    """
    boundary = f"----nicos{uuid.uuid4().hex}"
    sep = f"--{boundary}".encode()
    body = bytearray()
    for key, value in fields.items():
        if value is None:
            continue
        body += sep + b"\r\n"
        body += f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode()
        body += f"{value}\r\n".encode()
    ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    body += sep + b"\r\n"
    body += (
        f'Content-Disposition: form-data; name="assetData"; filename="{filename}"\r\n'
        f"Content-Type: {ctype}\r\n\r\n"
    ).encode()
    body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return bytes(body), f"multipart/form-data; boundary={boundary}"


def upload_asset(cfg, src, data, live_photo_video_id=None, visibility=None, opener=None):
    """Upload `data` as me, carrying over the source asset's dates and name.

    Returns (id, status) where status is `created` or `duplicate` — duplicate
    being the idempotent re-run path, with the id of the copy I already have.
    """
    filename = src.get("originalFileName") or f"{src['id']}.bin"
    fields = {
        "fileCreatedAt": src["fileCreatedAt"],
        "fileModifiedAt": src["fileModifiedAt"],
        "filename": filename,
        "visibility": visibility,
        "livePhotoVideoId": live_photo_video_id,
        "duration": src.get("duration"),
    }
    body, content_type = _multipart(fields, filename, data)
    req = urllib.request.Request(
        f"{cfg.url}/api/assets",
        data=body,
        headers=_headers(cfg, {"Content-Type": content_type}),
        method="POST",
    )
    got = http_json(req, timeout=TRANSFER_TIMEOUT, opener=opener)
    return got["id"], got.get("status")


def add_to_album(cfg, album_id, asset_ids, opener=None):
    if not asset_ids:
        return []
    return _post_json(
        cfg, f"/api/albums/{album_id}/assets", {"ids": asset_ids}, "PUT", opener=opener
    )


def remove_from_album(cfg, album_id, asset_ids, opener=None):
    if not asset_ids:
        return []
    return _post_json(
        cfg, f"/api/albums/{album_id}/assets", {"ids": asset_ids}, "DELETE", opener=opener
    )


def adopt_one(cfg, src, opener=None, log=log):
    """Copy one foreign asset (plus its motion half) into my library.

    Order is load-bearing: the video goes first, because the server validates on
    link that the motion asset is already mine (`onBeforeLink`).
    """
    src = _detailed(cfg, src, opener=opener)
    motion_id = None
    if src.get("livePhotoVideoId"):
        motion = asset(cfg, src["livePhotoVideoId"], opener=opener)
        motion_id, status = upload_asset(
            cfg,
            motion,
            download_original(cfg, motion["id"], opener=opener),
            # Motion halves must be hidden or they litter the timeline. The
            # server force-hides a linked video anyway; being explicit keeps a
            # re-run's upload byte-identical to the first.
            visibility="hidden",
            opener=opener,
        )
        log(f"  motion {motion.get('originalFileName')} -> {motion_id} ({status})")

    new_id, status = upload_asset(
        cfg,
        src,
        download_original(cfg, src["id"], opener=opener),
        live_photo_video_id=motion_id,
        opener=opener,
    )
    log(f"  still  {src.get('originalFileName')} -> {new_id} ({status})")
    return new_id


def _sources(cfg, me, opener=None):
    """(description, candidates) for whichever source mode is configured."""
    if cfg.owner:
        found = owner_assets(cfg, cfg.owner, opener=opener)
        return f"owner={cfg.owner}", found
    found = album_assets(cfg, cfg.source, opener=opener)
    return f"album={album(cfg, cfg.source, opener=opener).get('albumName')!r}", found


def run(cfg, opener=None, log=log):
    """Adopt every asset from the configured source that is not already mine.

    Read-only for the sharer unless `cfg.replace` is set, in which case their
    album entry is removed once my copy is safely in the target album. Their
    photo itself is never touched — there is no path here that deletes an asset
    this account does not own.
    """
    if not cfg.key:
        raise AdoptError(f"no API key (IMMICH_API_KEY_FILE, default {DEFAULT_KEY_FILE})")
    if not cfg.source and not cfg.owner:
        raise AdoptError("no source: pass --source ALBUM or --from-owner USER")
    if cfg.owner and not cfg.target:
        raise AdoptError("--from-owner has no album to default to; pass --target ALBUM")
    if cfg.replace and not cfg.source:
        raise AdoptError("--replace needs --source (there is no album entry to remove)")

    me = whoami(cfg, opener=opener)
    state = load_json(cfg.state_path, {"adopted": {}})
    known = state.get("adopted", {})

    where, candidates = _sources(cfg, me, opener=opener)
    dst = album(cfg, cfg.target_album, opener=opener)
    foreign = [a for a in candidates if a["ownerId"] != me]
    fresh = [a for a in foreign if a["id"] not in known]

    log(
        f"{where} target={dst.get('albumName')!r} candidates={len(candidates)} "
        f"foreign={len(foreign)} already_adopted={len(foreign) - len(fresh)} "
        f"new={len(fresh)} dry_run={cfg.dry_run} replace={cfg.replace}"
    )

    if cfg.dry_run:
        for a in fresh:
            live = " +motion" if a.get("livePhotoVideoId") else ""
            log(f"  would adopt {a.get('originalFileName') or a['id']}{live}")
        return []

    adopted = []
    for a in fresh:
        try:
            new_id = adopt_one(cfg, a, opener=opener, log=log)
        except Exception as exc:  # one bad file must not abandon the rest
            log(f"  FAILED {a.get('originalFileName') or a['id']}: {exc}")
            continue
        adopted.append((a["id"], new_id))
        known[a["id"]] = new_id

    if adopted:
        state["adopted"] = known
        try:
            ensure_dir(cfg.state_path.rsplit("/", 1)[0] or ".")
            save_json(cfg.state_path, state, indent=1, sort_keys=True)
        except OSError as exc:
            # Losing the cursor costs a re-download next run, which the server's
            # checksum dedupe makes harmless. Aborting here would instead skip
            # the album add below and leave the copies orphaned — far worse.
            log(f"  WARNING could not save state to {cfg.state_path}: {exc}")

    # Re-assert membership for every copy this source has ever produced, not just
    # the new ones: a copy someone removed from the album by hand should come
    # back, and the server no-ops the ones already in it (so no notification).
    mine_from_here = [known[a["id"]] for a in foreign if a["id"] in known]
    added = add_to_album(cfg, cfg.target_album, mine_from_here, opener=opener)
    landed = {r["id"] for r in added if r.get("success")}
    # A repeat run gets `duplicate` for copies already in the album. That is a
    # success for our purposes and must not be confused with `no_permission`,
    # which means the copy genuinely is not in there.
    already = {r["id"] for r in added if not r.get("success")
               and r.get("error") == "duplicate"}
    log(
        f"adopted {len(adopted)} new, {len(mine_from_here)} copies asserted into "
        f"{dst.get('albumName')!r} ({len(landed)} newly added, {len(already)} already in)"
    )

    if cfg.replace:
        # Only drop an original once its copy is provably in the target album.
        in_album = landed | already
        safe = [old for old, new in adopted if new in in_album]
        results = remove_from_album(cfg, cfg.source, safe, opener=opener)
        gone = sum(1 for r in results if r.get("success"))
        log(f"removed {gone}/{len(safe)} original entries from the source album")
        refused = [r["id"] for r in results if not r.get("success")]
        if refused:
            log(f"  refused (album not mine? need owner rights): {len(refused)}")

    return adopted


def _parse_args(argv):
    p = argparse.ArgumentParser(prog="immich-adopt", description=__doc__.split("\n")[0])
    src = p.add_mutually_exclusive_group()
    src.add_argument("--source", help="album id to adopt from")
    src.add_argument("--from-owner", dest="owner", help="user id to adopt everything from")
    p.add_argument("--target", help="album id for my copies (default: the source album)")
    p.add_argument("--state", help=f"json cursor path (default {DEFAULT_STATE})")
    p.add_argument(
        "--apply",
        action="store_true",
        help="actually write (default is a dry run that only lists)",
    )
    p.add_argument(
        "--replace",
        action="store_true",
        help="also remove the sharer's album entry once my copy is in (destructive "
        "to their attribution and comments; only works on albums I own)",
    )
    return p.parse_args(argv)


def main(argv=None, env=None, opener=None):
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    cfg = Config.from_env(env)
    overrides = {}
    if args.source:
        overrides["source"] = args.source
    if args.owner:
        overrides["owner"] = args.owner
    if args.target:
        overrides["target"] = args.target
    if args.state:
        overrides["state_path"] = args.state
    if args.apply:
        overrides["dry_run"] = False
    if args.replace:
        overrides["replace"] = True
    cfg = _replace(cfg, **overrides)

    try:
        run(cfg, opener=opener)
    except AdoptError as exc:
        log(f"FATAL {exc}")
        return 1
    if cfg.dry_run:
        log("dry run — nothing written. Re-run with --apply.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
