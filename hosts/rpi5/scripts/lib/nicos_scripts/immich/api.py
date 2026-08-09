"""The Immich REST calls the CLIP tools share.

Kept apart from store.py (disk + Postgres) because these are the only places that
need an API key, and apart from the two entry points because both of them resolve
albums by display name and both need to know which CLIP model is live.

`clip_model` and `ml_url` read Immich's own system config rather than taking the
answer from the environment. The model name is what makes a stored centroid valid
or worthless — deriving it from the server that will be compared against removes
the chance of the two drifting apart.
"""

import json
import urllib.request

from ..httpjson import get_json, post_json, put_json

BATCH = 500


def headers(cfg):
    return {"x-api-key": cfg.api_key}


def system_config(cfg, opener=None):
    # Long timeout on purpose: Immich is socket-activated with a 1800s idle timer
    # (hosts/rpi5/immich.nix), so this is usually the call that WAKES it, and a
    # cold NestJS boot on the Pi takes well past the 30s default.
    return get_json(
        f"{cfg.immich_url}/api/system-config", headers(cfg), timeout=120, opener=opener
    )


def clip_model(cfg, opener=None):
    """The live clip.modelName, preferring an explicit override."""
    if cfg.model:
        return cfg.model
    name = (
        system_config(cfg, opener)
        .get("machineLearning", {})
        .get("clip", {})
        .get("modelName")
    )
    if not name:
        raise SystemExit("could not read machineLearning.clip.modelName from Immich")
    return name


def ml_url(cfg, opener=None):
    """The first configured ML server, preferring an explicit override."""
    if cfg.ml_url:
        return cfg.ml_url
    urls = system_config(cfg, opener).get("machineLearning", {}).get("urls") or []
    if not urls:
        raise SystemExit("Immich has no machineLearning.urls configured")
    return urls[0].rstrip("/")


def ml_healthy(cfg, opener=None):
    """Is the ML server up? Same probe Immich uses: GET {url}/ping.

    ⚠️ /ping answers with the bare string `pong`, NOT JSON. Parsing it as JSON
    raises, and since any failure here means "not reachable", that silently
    reported a perfectly healthy beast as down. Status code only.

    Returns False rather than raising — "beast is off again" is the normal state
    here, not an error, and the caller simply tries on the next tick.
    """
    try:
        url = ml_url(cfg, opener=opener)
    except SystemExit:
        return False
    req = urllib.request.Request(f"{url}/ping")
    try:
        with (opener or urllib.request.urlopen)(req, timeout=10) as resp:
            return 200 <= resp.status < 300
    except Exception:  # noqa: BLE001 - any failure means "not reachable"
        return False


def start_job(cfg, name, force=False, opener=None):
    """Kick one of Immich's job queues.

    Used for `smartSearch` with force=False, i.e. "embed the assets that have no
    embedding". Immich never does this on its own — handleNightlyJobs queues
    missing THUMBNAILS and face clustering but not missing CLIP embeddings, so a
    SmartSearch job that failed while the ML server was down stays failed
    forever. This is the only thing that clears that backlog.
    """
    return put_json(
        f"{cfg.immich_url}/api/jobs/{name}",
        {"command": "start", "force": force},
        headers(cfg),
        opener=opener,
    )


def create_album(cfg, name, description="", opener=None):
    status, body = post_json(
        f"{cfg.immich_url}/api/albums",
        {"albumName": name, "description": description},
        headers(cfg),
        opener=opener,
    )
    if status not in (200, 201):
        raise SystemExit(f"could not create album {name!r}: HTTP {status} {body[:200]}")
    return json.loads(body)["id"]


def add_assets(cfg, album_id, asset_ids, opener=None, log=print):
    """PUT the ids in batches. Returns how many the server reported as added.

    Immich answers per id, and reports an id that was already in the album as
    `success: false` — so this count is "newly added", not "present".
    """
    added = 0
    for i in range(0, len(asset_ids), BATCH):
        chunk = asset_ids[i : i + BATCH]
        results = put_json(
            f"{cfg.immich_url}/api/albums/{album_id}/assets",
            {"ids": chunk},
            headers(cfg),
            opener=opener,
        )
        ok = sum(1 for r in results if r.get("success"))
        added += ok
        # Say WHY the rest were refused. The common one is `no_permission`:
        # a shared library contains other people's assets, and the API key can
        # only put its own owner's photos into its own owner's album. Reporting
        # a bare "53/78" made that look like a failure rather than a boundary.
        reasons = {}
        for r in results:
            if not r.get("success"):
                reasons[r.get("error", "unknown")] = reasons.get(r.get("error", "unknown"), 0) + 1
        detail = "".join(f", {n} {why}" for why, n in sorted(reasons.items()))
        log(f"batch {i // BATCH + 1}: {ok}/{len(chunk)} added{detail}")
    return added
