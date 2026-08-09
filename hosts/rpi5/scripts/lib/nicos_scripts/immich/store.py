"""Profile files on disk + the Immich Postgres reads the CLIP tools share.

Profiles live one JSON file per name under `<profile_dir>/<name>.json`:

    {"name", "model", "dim", "vector": [...], "built_from": {...}, "built_at"}

`model` is the guard that matters. Changing `services.immich.settings
.machineLearning.clip.modelName` re-embeds the whole library, which silently
invalidates every centroid built against the old model — so the model name is
recorded here and checked on load rather than discovered as mysteriously bad
matches later.
"""

import json
import re
import time
from pathlib import Path

from .vectors import format_vector

# The profile name reaches us from the workflow step's config box in the Immich
# UI, i.e. it is attacker-adjacent free text that we then use as a filename.
# Anchored allowlist, so `../../etc/passwd` is a rejected name and not a path.
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class ProfileError(Exception):
    """Profile missing, malformed, or built for a different CLIP model."""


def profile_path(profile_dir, name):
    if not NAME_RE.match(name or ""):
        raise ProfileError(f"invalid profile name {name!r}")
    return Path(profile_dir) / f"{name}.json"


def load_profile(profile_dir, name, model=None):
    path = profile_path(profile_dir, name)
    try:
        payload = json.loads(path.read_text())
    except FileNotFoundError:
        raise ProfileError(f"no profile {name!r} at {path} — run immich-clip-profile")
    except (OSError, ValueError) as e:
        raise ProfileError(f"profile {name!r} unreadable: {e}")

    vector = payload.get("vector")
    if not isinstance(vector, list) or not vector:
        raise ProfileError(f"profile {name!r} carries no vector")
    if model and payload.get("model") != model:
        raise ProfileError(
            f"profile {name!r} was built for CLIP model {payload.get('model')!r}, "
            f"but Immich now runs {model!r} — rebuild it"
        )
    return payload


def save_profile(profile_dir, name, model, vector, built_from, now=None):
    path = profile_path(profile_dir, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "name": name,
        "model": model,
        "dim": len(vector),
        "vector": [float(x) for x in vector],
        "built_from": built_from,
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now or time.time())),
    }
    # Write-then-rename: the sidecar reads this file on every classify call, and a
    # half-written profile would fail closed on every asset until the next run.
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(path)
    return payload


def connect_pg(cfg):
    """Connect to the Immich database.

    Imported lazily so this module (and its tests) load without psycopg2, the
    same way papra.tag_sync does it. With no host set, psycopg2 uses the unix
    socket and Postgres applies `local all all peer` — which is why the unit runs
    as User=immich and carries no password.
    """
    import psycopg2

    params = {k: v for k, v in cfg.pg.items() if v not in (None, "")}
    return psycopg2.connect(**params)


class AlbumError(Exception):
    """An album name that resolves to nothing, or to more than one album."""


def album_id_by_name(cur, name):
    """Album id for a display name, or None.

    Read from the database rather than the API on purpose: as of 3.1
    `GET /api/albums/{id}` reports `assetCount` but returns an empty `assets`
    list, so the membership has to come from `album_asset` anyway — and doing
    both here keeps the two halves consistent and unpaginated.
    """
    cur.execute(
        'SELECT id FROM album WHERE "albumName" = %s AND "deletedAt" IS NULL', (name,)
    )
    rows = cur.fetchall()
    if len(rows) > 1:
        raise AlbumError(f"{len(rows)} albums are named {name!r} — rename one")
    return str(rows[0][0]) if rows else None


def album_asset_ids(cur, album_id):
    cur.execute('SELECT "assetId" FROM album_asset WHERE "albumId" = %s', (album_id,))
    return [str(r[0]) for r in cur.fetchall()]


def existing_asset_ids(cur, asset_ids):
    """Which of these assets still exist and are not deleted.

    The drainer uses this to retire queue entries for photos deleted since they
    were queued — otherwise they sit there forever, keeping the "still waiting
    on embeddings" condition true and re-kicking the ML backlog job for nothing.
    """
    if not asset_ids:
        return set()
    cur.execute(
        'SELECT id FROM asset WHERE id = ANY(%s::uuid[]) AND "deletedAt" IS NULL',
        (list(asset_ids),),
    )
    return {str(r[0]) for r in cur.fetchall()}


def distance_to(cur, asset_id, vector):
    """Cosine distance between one asset's embedding and `vector`, or None.

    None means "Immich has not embedded this asset yet" — the normal state for a
    photo that was uploaded seconds ago, and the thing the sidecar waits on.

    This is a primary-key lookup, so it never touches the vchordrq index and
    therefore needs no `vchordrq.probes` GUC and returns an exact distance.
    """
    cur.execute(
        'SELECT embedding <=> %s::vector FROM smart_search WHERE "assetId" = %s',
        (format_vector(vector), asset_id),
    )
    row = cur.fetchone()
    return None if row is None else float(row[0])
