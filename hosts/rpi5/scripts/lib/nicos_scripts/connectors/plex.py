#!/usr/bin/env python3
"""
plex-to-ryot: Plex watch history -> Ryot V2, incrementally, per library.

Each run asks every Plex library for the items viewed since that library's cursor
(`lastViewedAt>>=`) and logs each finished view through the media plugin's
`media-activity-log`, stamped with Plex's `lastViewedAt`:

  * Movies         -> `complete` on a `movie` (movie.tmdb). Anime films stay here.
  * TV episodes    -> `episodes` on the `show` (show.tmdb), i.e. a `complete` on the
                      `show-episode`, found by its TMDB episode id, else by S/E.
  * Anime library  -> `progress` on an `anime` (anime.anilist) at the AniList episode
                      number, mapped with Fribb's anime-lists. Unmappable episodes
                      fall back to the TMDB show, with a warning.

V2's own Plex yank is not used: it walks the whole library every run, and it would
file the Anime library as TV shows.

Limits:
  * Plex keeps only the LAST view of an item, so rewatches between two runs
    collapse into one view.
  * A view counts once Plex has scrobbled it (viewCount >= 1, no viewOffset). An
    unfinished rewatch is skipped; finishing it moves lastViewedAt, so it comes back.
  * Absolute-numbered long runners (Detective Conan: TVDB seasons by year) have
    one season-less dataset entry; they map only when TMDB files the episode in
    season 1, its number then being the AniList one. Else: the TMDB show.

Cursor, per `<server#>/<section key>` in plex-cursor.json (unix seconds). With no
cursor, it starts at the newest Ryot event whose consumedOn is "Plex" — V1's
nightly import already put every earlier view into Ryot. A view is also skipped
when its target already has a complete/progress at that exact time. A view that
fails holds its library's cursor just before it, for MAX_ATTEMPTS runs.

Idempotency: submissionId `plex-<server#>-<ratingKey>-<lastViewedAt>`, with
submittedAt = the view time, so a retry replays rather than writes twice.

Stdlib only. Config via environment:
  PLEX_SERVERS            `url|token,url|token` (or PLEX_IMPORT_SERVERS)    [required]
  RYOT_API_KEY            Ryot V2 API key (X-Api-Key)                        [required]
  RYOT_URL                Ryot V2 base URL, without /api (default http://127.0.0.1:13350)
  PLEX_ANIME_LIBRARIES    comma-separated library titles (default Anime)
  STATE_DIR               state directory        (default /var/lib/ryot-connectors)

`--dry-run` lists what would be logged; it imports and writes nothing to Ryot and
leaves the cursor alone.
"""

import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, replace
from datetime import datetime, timezone

from .. import ryot
from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_str, missing_env
from ..state import ensure_dir, load_json, save_json

log = logger("plex-to-ryot")

DEFAULT_STATE_DIR = "/var/lib/ryot-connectors"
DEFAULT_RYOT_URL = "http://127.0.0.1:13350"
MEDIA = "ryot/media"
CONSUMED_ON = "Plex"
PROVIDERS = {"movie": "movie.tmdb", "show": "show.tmdb", "anime": "anime.anilist"}
PLEX_TYPE = {"movie": 1, "episode": 4}
PLEX_PAGE = 200
PLEX_TIMEOUT = 60
FRIBB_URL = "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json"
FRIBB_MAX_AGE = 7 * 24 * 3600
# A view that keeps failing stops holding its library's cursor after this many runs.
MAX_ATTEMPTS = 5
CHUNK = ryot.RYOTQL_PAGE


@dataclass(frozen=True)
class Config:
    servers: tuple = ()
    anime_libraries: frozenset = frozenset({"Anime"})
    ryot_url: str = DEFAULT_RYOT_URL
    ryot_api_key: str = ""
    state_dir: str = DEFAULT_STATE_DIR

    @classmethod
    def from_env(cls, env=None):
        raw = env_str("PLEX_SERVERS", "", env) or env_str("PLEX_IMPORT_SERVERS", "", env)
        return cls(
            servers=parse_servers(raw),
            anime_libraries=frozenset(
                t.strip() for t in env_str("PLEX_ANIME_LIBRARIES", "Anime", env).split(",") if t.strip()
            ),
            ryot_url=env_str("RYOT_URL", DEFAULT_RYOT_URL, env),
            ryot_api_key=env_str("RYOT_API_KEY", "", env),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
        )

    def path(self, name):
        return os.path.join(self.state_dir, name)


def parse_servers(raw):
    out = []
    for part in raw.split(","):
        url, sep, token = part.strip().partition("|")
        if sep and url and token:
            out.append((url.rstrip("/"), token))
    return tuple(out)


# ── Plex ──────────────────────────────────────────────────────────────────────


def plex_get(server, path, opener=None):
    """GET a Plex path as JSON. The token travels in a header, never in the URL,
    so no URL logged or raised here can carry it."""
    url, token = server
    req = urllib.request.Request(
        url + path, headers={"Accept": "application/json", "X-Plex-Token": token}
    )
    return http_json(req, timeout=PLEX_TIMEOUT, opener=opener).get("MediaContainer") or {}


def list_sections(server, opener=None):
    mc = plex_get(server, "/library/sections", opener=opener)
    return [
        {"key": str(d["key"]), "type": d.get("type"), "title": d.get("title", "")}
        for d in mc.get("Directory", [])
    ]


def viewed_since(server, section_key, plex_type, since, opener=None):
    """Items of `plex_type` in the section viewed at or after `since` (unix s)."""
    items, start = [], 0
    while True:
        path = (
            f"/library/sections/{section_key}/all?type={plex_type}"
            f"&lastViewedAt>>={int(since)}&includeGuids=1&sort=lastViewedAt:asc"
            f"&X-Plex-Container-Start={start}&X-Plex-Container-Size={PLEX_PAGE}"
        )
        page = plex_get(server, path, opener=opener).get("Metadata") or []
        items.extend(page)
        if len(page) < PLEX_PAGE:
            return items
        start += PLEX_PAGE


def guids(meta):
    """{"tmdb": "123", "tvdb": "456", ...} from a Plex `Guid` list."""
    out = {}
    for g in meta.get("Guid") or []:
        scheme, sep, value = str(g.get("id", "")).partition("://")
        if sep and value:
            out.setdefault(scheme, value)
    return out


def show_guids(server_no, server, rating_key, cache, opener=None):
    """The show's guids, cached per `<server#>:<ratingKey>` (they do not change)."""
    key = f"{server_no}:{rating_key}"
    if key not in cache:
        mc = plex_get(server, f"/library/metadata/{rating_key}?includeGuids=1", opener=opener)
        meta = (mc.get("Metadata") or [{}])[0]
        cache[key] = {"title": meta.get("title", ""), **guids(meta)}
    return cache[key]


def finished(item):
    return bool(item.get("lastViewedAt")) and (item.get("viewCount") or 0) >= 1 and not item.get(
        "viewOffset"
    )


# ── views ─────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class View:
    server: int
    library: str
    rating_key: str
    at: int
    title: str
    kind: str  # "movie" | "show" | "anime"
    tmdb: str = ""  # the movie's or the show's TMDB id
    tvdb: str = ""
    episode_tmdb: str = ""
    season: int = 0
    episode: int = 0
    anilist: str = ""
    anime_episode: int = 0

    @property
    def submission_id(self):
        return f"plex-{self.server}-{self.rating_key}-{self.at}"

    @property
    def label(self):
        if self.kind == "movie":
            return self.title
        return f"{self.title} S{self.season:02d}E{self.episode:02d}"


def movie_view(server_no, library, item):
    return View(
        server=server_no,
        library=library,
        rating_key=str(item["ratingKey"]),
        at=int(item["lastViewedAt"]),
        title=item.get("title", ""),
        kind="movie",
        tmdb=guids(item).get("tmdb", ""),
    )


def episode_view(server_no, library, item, show):
    return View(
        server=server_no,
        library=library,
        rating_key=str(item["ratingKey"]),
        at=int(item["lastViewedAt"]),
        title=show.get("title") or item.get("grandparentTitle", ""),
        kind="show",
        tmdb=show.get("tmdb", ""),
        tvdb=show.get("tvdb", ""),
        episode_tmdb=guids(item).get("tmdb", ""),
        season=int(item.get("parentIndex") or 0),
        episode=int(item.get("index") or 0),
    )


# ── anime mapping (Fribb anime-lists) ─────────────────────────────────────────


def compact_fribb(entries):
    """Keep what the mapping reads: [anilist, tvdb, tmdb_tv, season{tvdb,tmdb}, offset{tvdb,tmdb}]."""
    out = []
    for e in entries:
        tmdb = e.get("themoviedb_id")
        tmdb_tv = tmdb.get("tv") if isinstance(tmdb, dict) else None
        if not e.get("anilist_id") or not (e.get("tvdb_id") or tmdb_tv):
            continue
        out.append(
            [
                str(e["anilist_id"]),
                str(e["tvdb_id"]) if e.get("tvdb_id") else "",
                str(tmdb_tv) if tmdb_tv else "",
                e.get("season") or None,
                e.get("episode_offset") or None,
            ]
        )
    return out


def load_anime_index(cfg, now, opener=None, log=log):
    """The compacted dataset, refreshed weekly; a stale copy beats none."""
    path = cfg.path("plex-anime-lists.json")
    cached = load_json(path, {})
    if cached.get("entries") and now - cached.get("fetched_at", 0) < FRIBB_MAX_AGE:
        return cached["entries"]
    try:
        entries = compact_fribb(get_json(FRIBB_URL, timeout=120, opener=opener))
    except (urllib.error.URLError, OSError, ValueError) as e:
        log(f"WARN: anime-lists download failed ({e}); using the cached copy")
        return cached.get("entries") or []
    save_json(path, {"fetched_at": int(now), "entries": entries})
    return entries


def map_anime(index, tvdb, tmdb, season, episode):
    """(anilist id, AniList episode) for a TVDB/TMDB show episode, or None.

    Several AniList entries can share a season (Pokémon Concierge Part 2 =
    season 1 from episode 5): the one with the largest offset below the episode
    wins. An entry with no season is absolute-numbered and only trusted for S1.
    """
    if season < 1 or episode < 1:
        return None
    for scheme, show_id, col in (("tvdb", tvdb, 1), ("tmdb", tmdb, 2)):
        if not show_id:
            continue
        rows = [r for r in index if r[col] == show_id]
        best, ties = None, 0
        for r in rows:
            if not r[3] or r[3].get(scheme) != season:
                continue
            offset = (r[4] or {}).get(scheme) or 0
            if offset >= episode:
                continue
            if best is None or offset > best[1]:
                best, ties = (r[0], offset), 0
            elif offset == best[1]:
                ties += 1
        if best and not ties:
            return best[0], episode - best[1]
        absolute = absolute_anime(index, tvdb if scheme == "tvdb" else "", tmdb if scheme == "tmdb" else "")
        if season == 1 and absolute:
            return absolute, episode
    return None


def absolute_anime(index, tvdb, tmdb):
    """The AniList id of the show's one season-less (absolute-numbered) entry, or ""."""
    for show_id, col in ((tvdb, 1), (tmdb, 2)):
        rows = [r for r in index if show_id and r[col] == show_id and not r[3]]
        if len(rows) == 1:
            return rows[0][0]
    return ""


# ── Ryot ──────────────────────────────────────────────────────────────────────


def ms_to_iso(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(
        timespec="milliseconds"
    ).replace("+00:00", "Z")


def iso_to_s(iso):
    dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def providers_query():
    return ryot.ql_rows(
        "sandboxProvider",
        "p",
        ryot.ql_in(ryot.ql_col("p", "slug"), sorted(PROVIDERS.values())),
        {"id": ryot.ql_col("p", "id"), "slug": ryot.ql_col("p", "slug")},
    )


def latest_plex_event_query():
    return ryot.ql_rows(
        "event",
        "v",
        ryot.ql_cmp("eq", ryot.ql_prop("v", "consumedOn", "text"), ryot.ql_lit(CONSUMED_ON)),
        {"at": ryot.ql_col("v", "occurredAt")},
        limit=1,
        order_by=[{"direction": "desc", "expr": ryot.ql_col("v", "occurredAt")}],
    )


def entities_query(slug, provider_id, external_ids):
    where = ryot.ql_and(
        ryot.ql_eq("e", "entitySchemaSlug", slug),
        ryot.ql_eq("e", "providerId", provider_id),
        ryot.ql_in(ryot.ql_col("e", "externalId"), external_ids),
    )
    return ryot.ql_rows(
        "entity", "e", where, {"id": ryot.ql_col("e", "id"), "externalId": ryot.ql_col("e", "externalId")}
    )


def show_episodes_query(show_id, seasons):
    """A show's episodes in `seasons`, through show -> season -> episode."""
    col = ryot.ql_col
    joins = [
        ryot.ql_join("relationship", "se", ryot.ql_cmp("eq", col("se", "targetEntityId"), col("ep", "id"))),
        ryot.ql_join("relationship", "ss", ryot.ql_cmp("eq", col("ss", "targetEntityId"), col("se", "sourceEntityId"))),
    ]
    where = ryot.ql_and(
        ryot.ql_eq("ss", "sourceEntityId", show_id),
        ryot.ql_eq("ss", "relationshipSchemaSlug", "show-to-show-season"),
        ryot.ql_eq("se", "relationshipSchemaSlug", "show-season-to-show-episode"),
        ryot.ql_eq("ep", "entitySchemaSlug", "show-episode"),
        ryot.ql_in(ryot.ql_prop("ep", "seasonNumber", "number"), sorted(seasons)),
    )
    fields = {
        "id": col("ep", "id"),
        "externalId": col("ep", "externalId"),
        "season": ryot.ql_prop("ep", "seasonNumber"),
        "episode": ryot.ql_prop("ep", "episodeNumber"),
    }
    return ryot.ql_rows("entity", "ep", where, fields, joins=joins)


def episodes_by_tmdb_query(provider_id, external_ids):
    q = entities_query("show-episode", provider_id, external_ids)
    q["output"]["fields"] += [
        {"key": "season", "expr": ryot.ql_prop("e", "seasonNumber")},
        {"key": "episode", "expr": ryot.ql_prop("e", "episodeNumber")},
    ]
    return q


def events_query(entity_ids, since_ms):
    where = ryot.ql_and(
        ryot.ql_in(ryot.ql_col("v", "eventSchemaSlug"), ["complete", "progress"]),
        ryot.ql_in(ryot.ql_col("v", "entityId"), entity_ids),
        ryot.ql_cmp(
            "gte",
            ryot.ql_col("v", "occurredAt"),
            {"type": "cast", "target": "date", "expr": ryot.ql_lit(ms_to_iso(since_ms))},
        ),
    )
    fields = {
        "id": ryot.ql_col("v", "id"),
        "entityId": ryot.ql_col("v", "entityId"),
        "occurredAt": ryot.ql_col("v", "occurredAt"),
    }
    return ryot.ql_rows("event", "v", where, fields)


class Ryot:
    """Lookups and writes for one run; entity ids are cached in `entity_map`."""

    def __init__(self, client, entity_map, import_missing=True, log=log):
        self.client = client
        self.entity_map = entity_map
        self.import_missing = import_missing
        self.log = log
        self._providers = None

    @property
    def providers(self):
        if self._providers is None:
            rows = self.client.query({"p": providers_query()})["p"]["items"]
            self._providers = {r["slug"]: r["id"] for r in rows}
            missing = set(PROVIDERS.values()) - set(self._providers)
            if missing:
                raise RuntimeError(f"Ryot has no provider {', '.join(sorted(missing))}")
        return self._providers

    def latest_plex_view(self):
        """Unix seconds of the newest event consumed on Plex, or 0."""
        items = self.client.query({"m": latest_plex_event_query()})["m"]["items"]
        return iso_to_s(items[0]["at"]) if items else 0

    def resolve(self, kind, external_ids):
        """Fill entity_map[`kind:ext`] for `external_ids`; returns those still missing."""
        todo = sorted({x for x in external_ids if x and f"{kind}:{x}" not in self.entity_map})
        if not todo:
            return []
        provider = self.providers[PROVIDERS[kind]]
        for i in range(0, len(todo), CHUNK):
            q = entities_query(kind, provider, todo[i : i + CHUNK])
            for row in self.client.query_all("e", q):
                self.entity_map[f"{kind}:{row['externalId']}"] = row["id"]
        missing = [x for x in todo if f"{kind}:{x}" not in self.entity_map]
        if not self.import_missing:
            return missing
        left = []
        for x in missing:
            self.log(f"importing {PROVIDERS[kind]} {x}")
            try:
                entity = self.client.import_entity(provider, x)
            except RuntimeError as e:
                self.log(f"WARN: {e}")
                entity = ""
            if entity:
                self.entity_map[f"{kind}:{x}"] = entity
            else:
                left.append(x)
        return left

    def resolve_episodes(self, show_id, views):
        """{view submission id: (episode entity id, TMDB season, TMDB episode)}."""
        out, by_tmdb = {}, {}
        tmdb_ids = sorted({v.episode_tmdb for v in views if v.episode_tmdb})
        provider = self.providers[PROVIDERS["show"]]
        for i in range(0, len(tmdb_ids), CHUNK):
            for row in self.client.query_all("e", episodes_by_tmdb_query(provider, tmdb_ids[i : i + CHUNK])):
                by_tmdb[row["externalId"]] = (row["id"], int(row["season"]), int(row["episode"]))
        rest = [v for v in views if v.episode_tmdb not in by_tmdb]
        by_number = {}
        if rest:
            seasons = {v.season for v in rest}
            for row in self.client.query_all("e", show_episodes_query(show_id, seasons)):
                key = (int(row["season"]), int(row["episode"]))
                by_number[key] = (row["id"], *key)
        for v in views:
            ep = by_tmdb.get(v.episode_tmdb) or by_number.get((v.season, v.episode))
            if ep:
                out[v.submission_id] = ep
        return out

    def event_times(self, entity_ids, since_ms):
        """{(entity id, occurredAt unix s)} of completes/progress since `since_ms`."""
        out = set()
        ids = sorted(set(entity_ids))
        for i in range(0, len(ids), CHUNK):
            for row in self.client.query_all("c", events_query(ids[i : i + CHUNK], since_ms)):
                out.add((row["entityId"], iso_to_s(row["occurredAt"])))
        return out

    def log_view(self, view, target):
        """("saved" | "conflict" | "refused", result)."""
        payload = activity_payload(view, target)
        try:
            result = self.client.operation(
                MEDIA, "media-activity-log", payload, idempotency_key=payload["submissionId"]
            )
        except RuntimeError as e:
            # The key already wrote this view, under another mapping.
            if "operation-idempotency-conflict" in str(e):
                return "conflict", None
            raise
        ok = isinstance(result, dict) and result.get("status") == "saved"
        return ("saved" if ok else "refused"), result


def activity_payload(view, target):
    """`target` = {"entity": id} or {"show": id, "episode": id}."""
    at = ms_to_iso(view.at * 1000)
    when = {"kind": "date", "finishedOn": at}
    if view.kind == "anime":
        entry = {"kind": "progress", "entityId": target["entity"], "position": view.anime_episode}
    elif view.kind == "show":
        entry = {
            "kind": "episodes",
            "parentEntityId": target["show"],
            "episodeEntityIds": [target["episode"]],
            "when": when,
        }
    else:
        entry = {"kind": "complete", "entityId": target["entity"], "when": when}
    entry["consumedOn"] = CONSUMED_ON
    # submittedAt is also the progress event's occurredAt; it must not vary on retry.
    return {"submissionId": view.submission_id, "submittedAt": at, "entry": entry}


# ── run ───────────────────────────────────────────────────────────────────────


def collect_views(cfg, cursors, start_at, show_cache, opener=None, log=log):
    """{library key: [View]} of finished views after each library's cursor, oldest first."""
    out = {}
    for n, server in enumerate(cfg.servers, 1):
        for section in list_sections(server, opener=opener):
            if section["type"] not in ("movie", "show"):
                continue
            lib = f"{n}/{section['key']}"
            since = cursors.get(lib, start_at)
            anime = section["title"] in cfg.anime_libraries
            plex_type = PLEX_TYPE["movie" if section["type"] == "movie" else "episode"]
            items = viewed_since(server, section["key"], plex_type, since, opener=opener)
            views = []
            for item in items:
                if int(item.get("lastViewedAt") or 0) <= since or not finished(item):
                    continue
                if section["type"] == "movie":
                    v = movie_view(n, lib, item)
                else:
                    show = show_guids(n, server, item["grandparentRatingKey"], show_cache, opener)
                    v = episode_view(n, lib, item, show)
                    if anime:
                        v = replace(v, kind="anime")
                views.append(v)
            log(f"{lib} {section['title']!r}: {len(views)} new views since {ms_to_iso(since * 1000)}")
            out[lib] = sorted(views, key=lambda v: (v.at, v.rating_key))
    return out


def map_anime_views(views, index_loader, log=log):
    """Anime views get their AniList target; the rest fall back to the TMDB show."""
    index = None
    out = []
    for v in views:
        if v.kind != "anime":
            out.append(v)
            continue
        if index is None:
            index = index_loader()
        hit = map_anime(index, v.tvdb, v.tmdb, v.season, v.episode)
        if hit:
            out.append(replace(v, anilist=hit[0], anime_episode=hit[1]))
            continue
        # Kept for resolve_targets: TMDB may number the run absolutely.
        absolute = absolute_anime(index, v.tvdb, v.tmdb)
        if not absolute:
            log(f"WARN: no AniList mapping for {v.label}; logging it on the TMDB show")
        out.append(replace(v, kind="show", anilist=absolute))
    return out


def resolve_targets(rq, views, log=log):
    """(views, {submission id: target}) for the views whose entities resolve.

    A show view carrying an absolute AniList id becomes an anime view when TMDB
    files its episode in season 1 (Detective Conan: TVDB S32E01 = TMDB S1E1109 =
    AniList 235 ep 1109).
    """
    rq.resolve("movie", [v.tmdb for v in views if v.kind == "movie"])
    rq.resolve("show", [v.tmdb for v in views if v.kind == "show"])
    shows, episodes = {}, {}
    for v in views:
        if v.kind == "show" and f"show:{v.tmdb}" in rq.entity_map:
            shows.setdefault(rq.entity_map[f"show:{v.tmdb}"], []).append(v)
    for show_id, show_views in shows.items():
        for sid, ep in rq.resolve_episodes(show_id, show_views).items():
            episodes[sid] = (show_id, *ep)
    out = []
    for v in views:
        if v.kind == "show" and v.anilist:
            hit = episodes.get(v.submission_id)
            if hit and hit[2] == 1:
                v = replace(v, kind="anime", anime_episode=hit[3])
            else:
                log(f"WARN: no AniList mapping for {v.label}; logging it on the TMDB show")
                v = replace(v, anilist="")
        out.append(v)
    rq.resolve("anime", [v.anilist for v in out if v.kind == "anime"])
    targets = {}
    for v in out:
        if v.kind == "show":
            if v.submission_id in episodes:
                show_id, ep = episodes[v.submission_id][:2]
                targets[v.submission_id] = {"show": show_id, "episode": ep}
            continue
        entity = rq.entity_map.get(f"{v.kind}:{v.tmdb if v.kind == 'movie' else v.anilist}")
        if entity:
            targets[v.submission_id] = {"entity": entity}
    return out, targets


def advance(old, views, done):
    """The library's new cursor: past every view, or just before the first undone one."""
    pending = [v.at for v in views if v.submission_id not in done]
    if pending:
        return max(old, min(pending) - 1)
    return max([old] + [v.at for v in views])


def run(rq, views_by_lib, attempts, dry_run=False, log=log):
    """Log every view; returns (counts, done submission ids)."""
    views = [v for vs in views_by_lib.values() for v in vs]
    counts = {"logged": 0, "present": 0, "unmapped": 0, "failed": 0, "planned": 0}
    done = set()
    for v in views:
        if (v.kind in ("movie", "show") and not v.tmdb) or (v.kind == "show" and not v.episode):
            log(f"WARN: {v.label}: no TMDB id in Plex, skipped")
            counts["unmapped"] += 1
            done.add(v.submission_id)
    todo = [v for v in views if v.submission_id not in done]
    if not todo:
        return counts, done
    todo, targets = resolve_targets(rq, todo, log=log)
    entity_ids = [t.get("episode") or t["entity"] for t in targets.values()]
    present = rq.event_times(entity_ids, min(v.at for v in todo) * 1000) if entity_ids else set()
    for v in todo:
        target = targets.get(v.submission_id)
        if not target:
            if dry_run:
                log(f"would import + log {v.kind} {v.label} @ {ms_to_iso(v.at * 1000)}")
                counts["planned"] += 1
                continue
            log(f"WARN: {v.label}: no Ryot {v.kind} entity (attempt {attempts.get(v.submission_id, 0) + 1})")
            counts["failed"] += 1
            continue
        if (target.get("episode") or target["entity"], v.at) in present:
            counts["present"] += 1
            done.add(v.submission_id)
            continue
        what = f"anime {v.anilist} ep {v.anime_episode}" if v.kind == "anime" else v.kind
        if dry_run:
            log(f"would log {what}: {v.label} @ {ms_to_iso(v.at * 1000)}")
            counts["planned"] += 1
            continue
        status, result = rq.log_view(v, target)
        if status == "saved":
            counts["logged"] += 1
            done.add(v.submission_id)
            log(f"logged {what}: {v.label} @ {ms_to_iso(v.at * 1000)}")
        elif status == "conflict":
            log(f"WARN: {v.label} @ {ms_to_iso(v.at * 1000)} was already logged with another target")
            counts["present"] += 1
            done.add(v.submission_id)
        else:
            log(f"Ryot refused {v.label} @ {ms_to_iso(v.at * 1000)}: {result}")
            counts["failed"] += 1
    return counts, done


def main(argv=None, env=None, opener=None, sleep=time.sleep, now=time.time, log=log):
    argv = sys.argv[1:] if argv is None else argv
    dry_run = "--dry-run" in argv
    cfg = Config.from_env(env)
    missing = missing_env(("RYOT_API_KEY",), env)
    if not cfg.servers:
        missing.append("PLEX_SERVERS")
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        return 1
    ensure_dir(cfg.state_dir)

    state = load_json(cfg.path("plex-cursor.json"), {})
    cursors = state.get("cursors", {})
    attempts = state.get("attempts", {})
    show_cache = load_json(cfg.path("plex-shows.json"), {})
    entity_map = load_json(cfg.path("plex-entities.json"), {})
    client = ryot.Client(cfg.ryot_url, cfg.ryot_api_key, opener=opener, sleep=sleep, log=log)
    rq = Ryot(client, entity_map, import_missing=not dry_run, log=log)
    try:
        start_at = state.get("start_at")
        if start_at is None:
            start_at = rq.latest_plex_view()
            log(f"no cursor yet: starting after the newest Plex event in Ryot, {ms_to_iso(start_at * 1000)}")
        views_by_lib = collect_views(cfg, cursors, start_at, show_cache, opener=opener, log=log)
        save_json(cfg.path("plex-shows.json"), show_cache, sort_keys=True)
        loader = lambda: load_anime_index(cfg, now(), opener=opener, log=log)  # noqa: E731
        views_by_lib = {k: map_anime_views(vs, loader, log=log) for k, vs in views_by_lib.items()}
        counts, done = run(rq, views_by_lib, attempts, dry_run=dry_run, log=log)
    except (urllib.error.URLError, OSError, RuntimeError, KeyError, ValueError) as e:
        log(f"FATAL: {type(e).__name__}: {e}")
        return 1
    finally:
        if not dry_run:
            save_json(cfg.path("plex-entities.json"), entity_map, sort_keys=True)

    log("done: " + ", ".join(f"{n} {k}" for k, n in counts.items() if n or k == "logged"))
    if dry_run:
        return 0
    next_attempts = {}
    for vs in views_by_lib.values():
        for v in vs:
            if v.submission_id in done:
                continue
            n = attempts.get(v.submission_id, 0) + 1
            if n >= MAX_ATTEMPTS:
                log(f"WARN: giving up on {v.label} @ {ms_to_iso(v.at * 1000)} after {n} runs")
                done.add(v.submission_id)
            else:
                next_attempts[v.submission_id] = n
    new_cursors = dict(cursors)
    for lib, vs in views_by_lib.items():
        new_cursors[lib] = advance(cursors.get(lib, start_at), vs, done)
    save_json(
        cfg.path("plex-cursor.json"),
        {"start_at": start_at, "cursors": new_cursors, "attempts": next_attempts},
        indent=1,
        sort_keys=True,
    )
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
