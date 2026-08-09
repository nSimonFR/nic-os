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


def save_profile(profile_dir, name, model, vector, built_from, now=None, scoring="nearest"):
    path = profile_path(profile_dir, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "name": name,
        "model": model,
        "dim": len(vector),
        "vector": [float(x) for x in vector],
        "built_from": built_from,
        "scoring": scoring,
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


def seed_ids(profile):
    """Seeds to score against — [] means "use the centroid instead".

    Which is right depends on what the seeds have in common, and the two live
    profiles want opposite answers:

    * `food` — 19 photos of DIFFERENT subjects in different places. Averaging
      cancels the food and leaves the shared context, so the centroid drifts to
      the middle of the library (that is how an Eiffel Tower got in at 0.277).
      Nearest-seed fixes it.
    * `burgie` — 118 photos of ONE toy in wildly different places. Here the
      average is exactly right: the toy is the only consistent element, so it
      survives and everything else cancels. Nearest-seed instead matched the
      SCENE of whichever seed was closest — river selfies, apartment interiors,
      a desk fan — because those scenes really are near-identical to a seed.

    So it is a per-profile choice, not a global one. `scoring` records it.
    """
    built = profile.get("built_from") or {}
    if profile.get("scoring") == "centroid" or built.get("kind") != "seed":
        return []
    return list(built.get("assetIds") or [])


def nearest_seed_distance(cur, asset_id, ids):
    """Distance to the CLOSEST seed, rather than to their average.

    The centroid is a trap for a diverse seed set. Averaging 19 food photos that
    only agree with each other by ~0.59 cancels the food-specific directions and
    leaves what they share — daylight, phone snapshot, a trip — so the mean
    drifts toward the middle of the library and drags ordinary photos in. An
    Eiffel Tower shot measured 0.277 from the centroid while sitting 0.367 from
    the NEAREST actual food photo and 0.434 from the average one; a real gelato
    is 0.321 from the average seed, i.e. further than the tower was from the
    mean. Scoring against the nearest seed removes the artifact outright.

    Seed embeddings are read live rather than copied into the profile, so the
    profile stays small and can never hold a stale copy.
    """
    cur.execute(
        'SELECT MIN(a.embedding <=> b.embedding) FROM smart_search a, smart_search b '
        'WHERE a."assetId" = %s AND b."assetId" = ANY(%s::uuid[])',
        (asset_id, list(ids)),
    )
    row = cur.fetchone()
    return None if row is None or row[0] is None else float(row[0])


def score(cur, asset_id, profile):
    """Distance from one asset to a profile. None means "not embedded yet"."""
    ids = seed_ids(profile)
    if not ids:
        return distance_to(cur, asset_id, profile["vector"])

    # Split so that "this asset has no embedding" (undecided, queue it) stays
    # distinguishable from "the seeds have no embeddings" (a broken profile).
    cur.execute('SELECT 1 FROM smart_search WHERE "assetId" = %s', (asset_id,))
    if cur.fetchone() is None:
        return None

    nearest = nearest_seed_distance(cur, asset_id, ids)
    if nearest is None:
        # Every seed lost its embedding. Fall back to the stored centroid rather
        # than parking the asset forever on a profile that will never resolve.
        return distance_to(cur, asset_id, profile["vector"])
    return nearest


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
