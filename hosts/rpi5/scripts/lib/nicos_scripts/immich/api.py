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

from ..httpjson import get_json, post_json, put_json

BATCH = 500


def headers(cfg):
    return {"x-api-key": cfg.api_key}


def system_config(cfg, opener=None):
    return get_json(f"{cfg.immich_url}/api/system-config", headers(cfg), opener=opener)


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
        log(f"batch {i // BATCH + 1}: {ok}/{len(chunk)} added")
    return added
