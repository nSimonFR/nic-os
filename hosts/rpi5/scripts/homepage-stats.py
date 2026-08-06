#!/usr/bin/env python3
"""Tiny stats aggregation API for homepage-dashboard widgets.

Aggregates data from multiple service APIs into simple JSON endpoints,
refreshed once per day. Serves on 127.0.0.1:8087.

Endpoints (one per homepage tile, three stats each):
  /          — all stats
  /sure      — Sure (accounts, transactions, net worth)
  /openwebui — Open WebUI (models, chats, messages)
  /immich    — Immich (photos, videos, storage)
  /nextcloud — Nextcloud (active users, files, shares) — serverinfo OCS API
  /affine    — AFFiNE (workspaces, docs, storage) — GraphQL, summed across workspaces
  /beszel    — Beszel (systems, up, triggered alerts) — direct read-only SQLite
  /karakeep  — Karakeep (bookmarks, favorites, tags) — direct read-only SQLite
  /homeassistant — Home Assistant (people home, lights on, switches on) — /api/states
  /papra     — Papra (documents, tags, storage) — direct read-only SQLite
  /reactiveresume — Reactive Resume (resumes, users, views) — direct Postgres query
  /grampsweb — Gramps Web (people, families, events) — direct read-only SQLite, summed across trees
  /vaultwarden — Vaultwarden (items, users, devices) — direct read-only SQLite
  /wakapi    — Wakapi (coding hours: today, 30 days, all time) — direct read-only SQLite
  /dawarich  — Dawarich (points, trips, visits) — direct Postgres query (superuser)
  /airtrail  — AirTrail (flights, countries, hours) — direct Postgres query (superuser)
  /forgejo   — Forgejo (repositories, open issues, open PRs) — direct Postgres query (superuser)
  /beaverhabits — BeaverHabits (habits, done today, check-ins) — direct read-only SQLite (JSON blob)
  /ryot      — Ryot (media seen, hours seen, workouts) — direct Postgres query (superuser)

Every homepage tile reads its stats from here rather than from the app itself,
including the three that have a native homepage widget (Nextcloud, AFFiNE,
Beszel). Native widgets cannot be rate-limited from homepage's config, and
homepage's `customapi` widget defaults to refreshInterval = 10s — so the AFFiNE
tile used to POST a GraphQL query at AFFiNE every 10 seconds. Routing everything
through here means one fetch per day per service, and no API key or password
sitting in services-registry.nix.

Refresh cadence: 86400s (daily). Sure is socket-activated (hosts/rpi5/sure.nix)
with a 600s idle timer; the daily poll wakes it briefly (~10 min), then
it sleeps for the next ~23h50m. The stats are written to disk after each
refresh so a service restart preserves the last good values rather than
serving an empty payload until the next nightly refresh.

Papra, Reactive Resume, Gramps Web, Vaultwarden, Wakapi, Dawarich, AirTrail
and Forgejo are also socket-activated (except Dawarich, which is always-on),
but unlike Sure/Immich their stats come from reading their database directly
(SQLite, or Postgres as the postgres superuser via peer auth) rather than
their HTTP API, so polling never wakes them at all and no per-app API key or
role password is needed.

State file: $STATE_DIRECTORY/stats.json (set by systemd StateDirectory=).
Falls back to /var/lib/homepage-stats/stats.json if not in a unit.
"""

import glob
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time

CURL = os.environ.get("CURL_BIN", "curl")
SQLITE = os.environ.get("SQLITE_BIN", "sqlite3")
PSQL = os.environ.get("PSQL_BIN", "psql")
RUNUSER = os.environ.get("RUNUSER_BIN", "runuser")
ENV_FILE = "/run/homepage-dashboard/env"
OWUI_DB = "/var/lib/private/open-webui/data/webui.db"
# Read karakeep's SQLite directly (read-only) instead of its HTTP API: no API
# key needed, and — crucially — it never wakes karakeep, so the socket-activated
# idle-sleep (hosts/rpi5/karakeep.nix) is preserved. -readonly avoids creating
# root-owned -wal/-shm files that would break karakeep (runs as the karakeep user).
KARAKEEP_DB = "/var/lib/karakeep/db.db"
# Same direct-DB-read trick for Papra (hosts/rpi5/papra.nix) and Gramps Web
# (hosts/rpi5/gramps-web.nix) — both socket-activated, both read read-only so polling
# never wakes them.
PAPRA_DB = "/var/lib/papra/db.sqlite"
GRAMPS_TREES_GLOB = "/var/lib/gramps-web/data/grampsdb/*/sqlite.db"
# Reactive Resume's Postgres role/db (hosts/rpi5/reactive-resume.nix, shared cluster).
# pg_hba requires scram-sha-256 for this role (see pg_hba_file_rules), so the
# password is read from the same agenix secret reactive-resume-env uses; root
# can read it despite owner=postgres (root bypasses file permission bits).
# Postgres isn't part of the socket-activated tier, so querying it never wakes
# the reactive-resume Node service either.
RXRESUME_DB = "reactive_resume"
RXRESUME_ROLE = "reactive_resume"
RXRESUME_PW_FILE = "/run/agenix/reactive-resume-db-password"
# Vaultwarden and Wakapi: same direct-SQLite-read trick as Papra/Karakeep above.
VAULTWARDEN_DB = "/var/lib/vaultwarden/db.sqlite3"
WAKAPI_DB = "/var/lib/wakapi/wakapi.db"
# Beszel's PocketBase database (hosts/rpi5/monitoring.nix). DynamicUser + StateDirectory
# puts it under /var/lib/private, which is 0700 root — this service runs as root, so
# the same read-only-SQLite trick applies. Reading it here replaces the native beszel
# widget, which needed a superuser password in plaintext in services-registry.nix.
BESZEL_DB = "/var/lib/private/beszel-hub/beszel_data/data.db"
# AFFiNE (hosts/rpi5/affine.nix) and Nextcloud (hosts/rpi5/nextcloud.nix) are the two tiles that
# genuinely need an HTTP API — both are always-on, so the daily poll wakes nothing.
AFFINE_GRAPHQL_URL = "http://127.0.0.1:13010/graphql"
AFFINE_QUERY = "{ workspaces { blobsSize docs(pagination: {first: 0}) { totalCount } } }"
NEXTCLOUD_INFO_URL = "http://127.0.0.1:8091/ocs/v2.php/apps/serverinfo/api/v1/info?format=json"
# BeaverHabits (hosts/rpi5/beaverhabits.nix): the whole habit list is one JSON blob per
# user in habit_list.data — read-only, so polling never wakes the idle service.
BEAVERHABITS_DB = "/var/lib/beaverhabits/habits.db"
# ShowMyCards (hosts/rpi5/showmycards.nix): socket-activated with a 600s idle timer, so
# the same read-only-SQLite trick applies — its HTTP API is the ONLY thing that can
# wake it, and a widget polling :8330 would pin both processes awake permanently on
# a 3.9 GB box. The DB is 0750 showmycards:showmycards; this service runs as root.
# Lives on /mnt/data, never / (the catalogue is ~0.9 GB).
SHOWMYCARDS_DB = "/mnt/data/showmycards/database.db"
# Dawarich, AirTrail, Forgejo: queried as the postgres superuser over the
# local Unix socket (peer auth via `runuser -u postgres`) rather than each
# app's own role. Simpler than the Reactive Resume password dance above —
# no agenix secret needed — and works regardless of whether the app itself
# authenticates via password (dawarich/airtrail) or peer auth on a Unix
# socket (forgejo, which has no TCP/password role at all).
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/homepage-stats")
STATE_FILE = os.path.join(STATE_DIR, "stats.json")
REFRESH_INTERVAL = 86400  # seconds — see module docstring
# Bump whenever a fetcher changes WHICH fields it reports (renaming wakapi's
# heartbeats→today, say), so the cache from the previous shape is discarded.
# backfill_missing only re-fetches keys that are entirely absent, so without this a
# key whose fields were renamed would keep serving the old shape — blanking its tile
# — until the next daily refresh, up to 24h after the rebuild that changed it.
STATS_SCHEMA = 2

stats = {
    "sure": {}, "openwebui": {}, "immich": {}, "karakeep": {}, "homeassistant": {},
    "papra": {}, "reactiveresume": {}, "grampsweb": {},
    "vaultwarden": {}, "wakapi": {}, "dawarich": {}, "airtrail": {}, "forgejo": {},
    "beaverhabits": {}, "ryot": {}, "showmycards": {},
    "nextcloud": {}, "affine": {}, "beszel": {},
}
stats_lock = threading.Lock()


def env_var(name):
    """Read a HOMEPAGE_VAR_* value out of the env file homepage-dashboard shares.

    Written by the homepage-dashboard-env oneshot (hosts/rpi5/homepage.nix), so the
    secrets live in exactly one place for both the dashboard and this aggregator.
    """
    with open(ENV_FILE) as f:
        for line in f:
            if name in line:
                return line.split("=", 1)[1].strip()
    raise KeyError(f"{name} not in {ENV_FILE}")


def fetch_sure():
    try:
        key = env_var("SURE_KEY")
        # Sure is mounted under /sure now (RAILS_RELATIVE_URL_ROOT, see sure.nix),
        # so its API lives at /sure/api/v1/* — the root path 404s. Hit :13334
        # (socket-activate) so the daily poll wakes Puma briefly, then it sleeps.
        accts = json.loads(subprocess.check_output([
            CURL, "-sf",
            "http://127.0.0.1:13334/sure/api/v1/accounts",
            "-H", f"X-Api-Key: {key}", "-H", "Accept: application/json"
        ]))
        txns = json.loads(subprocess.check_output([
            CURL, "-sf",
            "http://127.0.0.1:13334/sure/api/v1/transactions?per_page=1",
            "-H", f"X-Api-Key: {key}", "-H", "Accept: application/json"
        ]))
        accounts = accts.get("accounts", [])

        def parse_bal(s):
            num = re.sub(r"[^\d.\-]", "", s.replace(",", ""))
            return float(num) if num else 0

        assets = sum(parse_bal(a["balance"]) for a in accounts if a["classification"] == "asset")
        liabilities = sum(parse_bal(a["balance"]) for a in accounts if a["classification"] == "liability")
        with stats_lock:
            stats["sure"] = {
                "accounts": accts.get("pagination", {}).get("total_count", 0),
                "transactions": txns.get("pagination", {}).get("total_count", 0),
                "net_worth": round(assets - liabilities),
            }
    except Exception as e:
        with stats_lock:
            stats["sure"]["error"] = str(e)


def fetch_openwebui():
    try:
        models = json.loads(subprocess.check_output([
            CURL, "-sf", "http://127.0.0.1:4001/v1/models"
        ]))
        chats = subprocess.check_output([
            SQLITE, OWUI_DB, "SELECT COUNT(*) FROM chat;"
        ]).decode().strip()
        messages = subprocess.check_output([
            SQLITE, OWUI_DB, "SELECT COUNT(*) FROM chat_message;"
        ]).decode().strip()
        with stats_lock:
            stats["openwebui"] = {
                "models": len(models.get("data", [])),
                "chats": int(chats),
                "messages": int(messages),
            }
    except Exception as e:
        with stats_lock:
            stats["openwebui"]["error"] = str(e)


def load_cache():
    try:
        with open(STATE_FILE) as f:
            payload = json.load(f)
        if payload.get("_schema") != STATS_SCHEMA:
            # Leave every key empty so backfill_missing does a full fetch, dated now.
            print(f"cache schema {payload.get('_schema')} != {STATS_SCHEMA}, refetching all",
                  file=sys.stderr)
            return 0
        with stats_lock:
            for k in stats:
                stats[k] = payload.get(k, {})
        return payload.get("_fetched_at", 0)
    except FileNotFoundError:
        return 0
    except Exception as e:
        print(f"cache load failed: {e}", file=sys.stderr)
        return 0


def save_cache(ts):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with stats_lock:
            payload = {k: dict(v) for k, v in stats.items()}
            payload["_fetched_at"] = ts
            payload["_schema"] = STATS_SCHEMA
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        print(f"cache save failed: {e}", file=sys.stderr)


def fetch_immich():
    try:
        key = env_var("IMMICH_KEY")
        # Hit the externally-facing port (2283) so the daily fetch goes
        # through the socket-activate proxy, wakes immich-server briefly,
        # then lets it sleep again (same pattern as fetch_sure on :13334).
        data = json.loads(subprocess.check_output([
            CURL, "-sf",
            "http://127.0.0.1:2283/api/server/statistics",
            "-H", f"x-api-key: {key}", "-H", "Accept: application/json"
        ]))
        with stats_lock:
            stats["immich"] = {
                "photos": data.get("photos", 0),
                "videos": data.get("videos", 0),
                "usage":  data.get("usage", 0),
            }
    except Exception as e:
        with stats_lock:
            stats["immich"]["error"] = str(e)


def fetch_nextcloud():
    # serverinfo's OCS API, authenticated with the NC-Token it was configured with
    # (hosts/rpi5/nextcloud.nix enables the "serverinfo" app for exactly this). Basic auth
    # as nsimon 401s. Replaces the native `nextcloud` homepage widget, which always
    # renders freespace/activeusers/numfiles/numshares and only lets `fields` filter
    # which of them survive.
    try:
        data = json.loads(subprocess.check_output([
            CURL, "-sf", NEXTCLOUD_INFO_URL,
            "-H", f"NC-Token: {env_var('NEXTCLOUD_PASSWORD')}",
            "-H", "OCS-APIRequest: true",
        ]))["ocs"]["data"]
        with stats_lock:
            stats["nextcloud"] = {
                "users":  data["activeUsers"]["last24hours"],
                "files":  data["nextcloud"]["storage"]["num_files"],
                "shares": data["nextcloud"]["shares"]["num_shares"],
            }
    except Exception as e:
        with stats_lock:
            stats["nextcloud"]["error"] = str(e)


def fetch_affine():
    # Summed across every workspace. The tile this replaces read workspaces[0]
    # only, which is the 3-doc scratch workspace rather than the ~7.5k-doc main
    # one (see project_affine_workspaces_courses) — so its numbers were both
    # arbitrary and re-fetched every 10 seconds.
    try:
        data = json.loads(subprocess.check_output([
            CURL, "-sf", AFFINE_GRAPHQL_URL,
            "-H", "Content-Type: application/json",
            "-H", f"Authorization: Bearer {env_var('AFFINE_TOKEN')}",
            "-d", json.dumps({"query": AFFINE_QUERY}),
        ]))
        workspaces = data["data"]["workspaces"]
        with stats_lock:
            stats["affine"] = {
                "workspaces": len(workspaces),
                "docs":       sum(w["docs"]["totalCount"] for w in workspaces),
                "storage":    sum(w["blobsSize"] for w in workspaces),
            }
    except Exception as e:
        with stats_lock:
            stats["affine"]["error"] = str(e)


def fetch_beszel():
    # Read-only direct SQLite query against Beszel's PocketBase DB — same trick as
    # fetch_karakeep. `alerts.triggered` is the interesting one: it's what actually
    # fired, not how many alert rules exist.
    def count(sql):
        return int(subprocess.check_output(
            [SQLITE, "-readonly", BESZEL_DB, sql]
        ).decode().strip() or 0)
    try:
        with stats_lock:
            stats["beszel"] = {
                "systems": count("SELECT COUNT(*) FROM systems;"),
                "up":      count("SELECT COUNT(*) FROM systems WHERE status = 'up';"),
                "alerts":  count("SELECT COUNT(*) FROM alerts WHERE triggered = 1;"),
            }
    except Exception as e:
        with stats_lock:
            stats["beszel"]["error"] = str(e)


def fetch_karakeep():
    # Read-only direct SQLite query — no API key, never wakes karakeep.
    def count(sql):
        return int(subprocess.check_output(
            [SQLITE, "-readonly", KARAKEEP_DB, sql]
        ).decode().strip() or 0)
    try:
        with stats_lock:
            stats["karakeep"] = {
                "bookmarks": count("SELECT COUNT(*) FROM bookmarks;"),
                "favorites": count("SELECT COUNT(*) FROM bookmarks WHERE favourited = 1;"),
                "tags":      count("SELECT COUNT(*) FROM bookmarkTags;"),
            }
    except Exception as e:
        with stats_lock:
            stats["karakeep"]["error"] = str(e)


def fetch_papra():
    # Read-only direct SQLite query — same trick as fetch_karakeep, never wakes papra.
    def q(sql):
        return subprocess.check_output(
            [SQLITE, "-readonly", PAPRA_DB, sql]
        ).decode().strip()
    try:
        with stats_lock:
            stats["papra"] = {
                "documents": int(q("SELECT COUNT(*) FROM documents WHERE is_deleted = 0;") or 0),
                "tags":      int(q("SELECT COUNT(*) FROM tags;") or 0),
                "size":      int(q("SELECT COALESCE(SUM(original_size),0) FROM documents WHERE is_deleted = 0;") or 0),
            }
    except Exception as e:
        with stats_lock:
            stats["papra"]["error"] = str(e)


def fetch_beaverhabits():
    # Read-only direct SQLite query — same trick as fetch_papra, never wakes the
    # socket-activated beaverhabits service. The habit list is a compact JSON blob
    # per user in habit_list.data: {"habits":[{name,status,records:[{day,done}]}]}.
    # "archive" status = habit the user retired, so it's excluded from the counts.
    try:
        raw = subprocess.check_output(
            [SQLITE, "-readonly", BEAVERHABITS_DB, "SELECT data FROM habit_list;"]
        ).decode()
        today = time.strftime("%Y-%m-%d")
        habits = done_today = checkins = 0
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            active = [h for h in json.loads(line).get("habits", [])
                      if h.get("status") != "archive"]
            habits += len(active)
            for h in active:
                recs = h.get("records", [])
                checkins += sum(1 for r in recs if r.get("done"))
                if any(r.get("day") == today and r.get("done") for r in recs):
                    done_today += 1
        with stats_lock:
            stats["beaverhabits"] = {
                "habits":     habits,
                "done_today": done_today,
                "checkins":   checkins,
            }
    except Exception as e:
        with stats_lock:
            stats["beaverhabits"]["error"] = str(e)


# Collection value in EUR, foil-aware. Deliberately NOT ShowMyCards' own
# total_collection_value: that reports 226.48 for this data and no combination of
# prices.{eur,usd}{,_foil} reproduces it (eur=148.87, usd=190.13), so it is some
# other currency or blend. EUR is what the user actually wants, and reading it here
# means the figure never depends on waking the service.
#
# The treatment CASE matters: a foil row priced from prices.eur silently contributes
# 0 whenever a printing is foil-only, which is how an earlier naive sum came out at
# 125.07 instead of 148.87. Coverage is currently 623/623 cards priced, so this is a
# complete total rather than a floor — worth re-checking if it ever drifts.
SHOWMYCARDS_VALUE_SQL = """
with px as (
  select i.quantity q, i.treatment t,
         (select raw_json from cards where scryfall_id = i.scryfall_id) j
  from inventories i)
select round(coalesce(sum(q * cast(
  case t
    when 'foil'   then coalesce(json_extract(j,'$.prices.eur_foil'),   json_extract(j,'$.prices.eur'))
    when 'etched' then coalesce(json_extract(j,'$.prices.eur_etched'), json_extract(j,'$.prices.eur_foil'), json_extract(j,'$.prices.eur'))
    else json_extract(j,'$.prices.eur')
  end as real)),0),2) from px;
"""
def fetch_showmycards():
    # Read-only direct SQLite query — same trick as fetch_papra, never wakes the
    # socket-activated showmycards pair.
    #
    # `cards` is the 171k-printing Scryfall catalogue, NOT the collection: counting
    # it would report 171182 owned cards. The collection is `inventories`, and a row
    # there is a stack, so cards = SUM(quantity), not COUNT(*).
    def q(sql):
        return subprocess.check_output(
            [SQLITE, "-readonly", SHOWMYCARDS_DB, sql]
        ).decode().strip()
    try:
        with stats_lock:
            stats["showmycards"] = {
                "cards":     int(q("SELECT COALESCE(SUM(quantity),0) FROM inventories;") or 0),
                "decks":     int(q("SELECT COUNT(*) FROM lists;") or 0),
                "locations": int(q("SELECT COUNT(*) FROM storage_locations;") or 0),
                "value":     round(float(q(SHOWMYCARDS_VALUE_SQL) or 0), 2),
            }
    except Exception as e:
        with stats_lock:
            stats["showmycards"]["error"] = str(e)


def fetch_reactive_resume():
    def q(sql):
        env = dict(os.environ, PGPASSWORD=open(RXRESUME_PW_FILE).read().strip())
        return subprocess.check_output([
            PSQL, "-h", "127.0.0.1", "-p", "5432",
            "-U", RXRESUME_ROLE, "-d", RXRESUME_DB, "-tAc", sql,
        ], env=env).decode().strip()
    try:
        with stats_lock:
            stats["reactiveresume"] = {
                "resumes": int(q("SELECT COUNT(*) FROM resume;") or 0),
                "users":   int(q('SELECT COUNT(*) FROM "user";') or 0),
                "views":   int(q("SELECT COALESCE(SUM(views), 0) FROM resume_statistics;") or 0),
            }
    except Exception as e:
        with stats_lock:
            stats["reactiveresume"]["error"] = str(e)


def fetch_gramps_web():
    # Multi-tree (hosts/rpi5/gramps-web.nix tree = "*"): sum counts across every
    # tree's SQLite database rather than assuming a single tree.
    def sum_count(table):
        total = 0
        for db in glob.glob(GRAMPS_TREES_GLOB):
            out = subprocess.check_output(
                [SQLITE, "-readonly", db, f"SELECT COUNT(*) FROM {table};"]
            ).decode().strip()
            total += int(out or 0)
        return total
    try:
        with stats_lock:
            stats["grampsweb"] = {
                "people":   sum_count("person"),
                "families": sum_count("family"),
                "events":   sum_count("event"),
            }
    except Exception as e:
        with stats_lock:
            stats["grampsweb"]["error"] = str(e)


def fetch_vaultwarden():
    # Read-only direct SQLite query — same trick as fetch_karakeep, never wakes vaultwarden.
    def count(sql):
        return int(subprocess.check_output(
            [SQLITE, "-readonly", VAULTWARDEN_DB, sql]
        ).decode().strip() or 0)
    try:
        with stats_lock:
            stats["vaultwarden"] = {
                "items":   count("SELECT COUNT(*) FROM ciphers WHERE deleted_at IS NULL;"),
                "users":   count("SELECT COUNT(*) FROM users;"),
                "devices": count("SELECT COUNT(*) FROM devices;"),
            }
    except Exception as e:
        with stats_lock:
            stats["vaultwarden"]["error"] = str(e)


def fetch_wakapi():
    # Coding time, not row counts: `durations` is wakapi's own precomputed
    # heartbeat-coalescing table (the same thing its summaries are built from), and
    # its `duration` column is NANOSECONDS — hence /3.6e12 for hours.
    #
    # `time` values carry a UTC offset (e.g. "…21:39:51.902+02:00"), so date() on
    # them yields a UTC date; the 'localtime' modifier on both sides makes "today"
    # mean the local day rather than shifting by two hours after midnight.
    def hours(where=""):
        ns = int(subprocess.check_output([
            SQLITE, "-readonly", WAKAPI_DB,
            f"SELECT COALESCE(SUM(duration), 0) FROM durations {where};",
        ]).decode().strip() or 0)
        return round(ns / 3.6e12, 1)
    try:
        with stats_lock:
            stats["wakapi"] = {
                "today":    hours("WHERE date(time, 'localtime') = date('now', 'localtime')"),
                "last_30d": hours("WHERE time >= datetime('now', '-30 day')"),
                "total":    hours(),
            }
    except Exception as e:
        with stats_lock:
            stats["wakapi"]["error"] = str(e)


def pg_superuser_query(db, sql):
    # postgres superuser via peer auth on the local Unix socket — works for
    # any DB regardless of the app's own auth (password role or, like
    # forgejo, peer-only with no password role at all). Read-only SELECTs.
    return subprocess.check_output(
        [RUNUSER, "-u", "postgres", "--", PSQL, "-d", db, "-tAc", sql]
    ).decode().strip()


def fetch_dawarich():
    try:
        with stats_lock:
            stats["dawarich"] = {
                "points": int(pg_superuser_query("dawarich", "SELECT COUNT(*) FROM points;") or 0),
                "trips":  int(pg_superuser_query("dawarich", "SELECT COUNT(*) FROM trips;") or 0),
                "visits": int(pg_superuser_query("dawarich", "SELECT COUNT(*) FROM visits;") or 0),
            }
    except Exception as e:
        with stats_lock:
            stats["dawarich"]["error"] = str(e)


def fetch_airtrail():
    # flight.duration is SECONDS, not minutes: the longest flight on record is
    # 42872, i.e. 11h54m. Dividing by 60 reported 7922 "hours" for 29 flights;
    # the real total is 132.
    try:
        with stats_lock:
            stats["airtrail"] = {
                "flights":   int(pg_superuser_query("airtrail", "SELECT COUNT(*) FROM flight;") or 0),
                "countries": int(pg_superuser_query("airtrail", "SELECT COUNT(*) FROM visited_country;") or 0),
                "hours":     round(int(pg_superuser_query("airtrail", "SELECT COALESCE(SUM(duration),0) FROM flight;") or 0) / 3600),
            }
    except Exception as e:
        with stats_lock:
            stats["airtrail"]["error"] = str(e)


# Hours of media actually consumed. daily_user_activity is Ryot's own per-day
# rollup — the table its dashboard reads — and every *_duration column in it is
# MINUTES (cross-checked: workout_duration sums to 167 against workout.duration's
# 10026 seconds). total_duration is exactly the sum of the per-type durations.
#
# video_game_duration is subtracted because the Steam import (project_ryot_connectors)
# dumps lifetime playtime onto its import date: 350736 minutes — 5846 h — all on
# 2026-07-23, which would swamp everything else. visual_novel_duration goes with it
# for the same reason. Subtracting from total_duration rather than adding up the
# media columns means a media type Ryot adds later is counted automatically.
RYOT_MEDIA_HOURS_SQL = """
SELECT COALESCE(SUM(total_duration - video_game_duration
                    - visual_novel_duration - workout_duration), 0)
FROM daily_user_activity;
"""
def fetch_ryot():
    # Ryot (hosts/rpi5/ryot.nix) is Postgres-backed. Read its counts directly as the
    # postgres superuser — no API token, and (like the other direct-read tiles)
    # it never touches Ryot's own HTTP layer. Ryot is always-on (not socket-
    # activated), so this is purely to avoid holding an API key on the tile.
    #
    # "seen" counts finished consumption events (each episode of a show is its own
    # row), NOT `metadata`, which is the 16.8k-row metadata catalogue Ryot has
    # fetched from providers and is nothing to do with what was watched.
    try:
        with stats_lock:
            stats["ryot"] = {
                "seen":     int(pg_superuser_query("ryot", "SELECT COUNT(*) FROM seen WHERE state = 'completed';") or 0),
                "hours":    round(int(pg_superuser_query("ryot", RYOT_MEDIA_HOURS_SQL) or 0) / 60),
                "workouts": int(pg_superuser_query("ryot", "SELECT COUNT(*) FROM workout;") or 0),
            }
    except Exception as e:
        with stats_lock:
            stats["ryot"]["error"] = str(e)


def fetch_forgejo():
    try:
        with stats_lock:
            stats["forgejo"] = {
                "repositories": int(pg_superuser_query("forgejo", "SELECT COUNT(*) FROM repository;") or 0),
                "issues":       int(pg_superuser_query("forgejo", "SELECT COUNT(*) FROM issue WHERE is_pull=false AND is_closed=false;") or 0),
                "pulls":        int(pg_superuser_query("forgejo", "SELECT COUNT(*) FROM issue WHERE is_pull=true AND is_closed=false;") or 0),
            }
    except Exception as e:
        with stats_lock:
            stats["forgejo"]["error"] = str(e)


def fetch_homeassistant():
    # HA is always-on (not socket-activated), so polling it doesn't wake anything.
    # It's routed through this daily-cached aggregator only for consistency with
    # the other tiles — note the counts can be up to REFRESH_INTERVAL stale.
    try:
        token = env_var("HA_TOKEN")
        states = json.loads(subprocess.check_output([
            CURL, "-sf", "http://127.0.0.1:8123/api/states",
            "-H", f"Authorization: Bearer {token}", "-H", "Content-Type: application/json"
        ]))

        def count(prefix, st):
            return sum(1 for e in states
                       if e.get("entity_id", "").startswith(prefix) and e.get("state") == st)

        with stats_lock:
            stats["homeassistant"] = {
                "people_home": count("person.", "home"),
                "lights_on":   count("light.", "on"),
                "switches_on": count("switch.", "on"),
            }
    except Exception as e:
        with stats_lock:
            stats["homeassistant"]["error"] = str(e)


# Single source for "which fetcher owns which stats key", used by both the daily
# refresh and the startup backfill. Keeping it a dict rather than a call list means
# a newly added widget cannot be wired into one and forgotten in the other.
FETCHERS = {
    "sure": fetch_sure,
    "openwebui": fetch_openwebui,
    "immich": fetch_immich,
    "nextcloud": fetch_nextcloud,
    "affine": fetch_affine,
    "beszel": fetch_beszel,
    "karakeep": fetch_karakeep,
    "homeassistant": fetch_homeassistant,
    "papra": fetch_papra,
    "showmycards": fetch_showmycards,
    "reactiveresume": fetch_reactive_resume,
    "grampsweb": fetch_gramps_web,
    "vaultwarden": fetch_vaultwarden,
    "wakapi": fetch_wakapi,
    "dawarich": fetch_dawarich,
    "airtrail": fetch_airtrail,
    "forgejo": fetch_forgejo,
    "beaverhabits": fetch_beaverhabits,
    "ryot": fetch_ryot,
}


def backfill_missing(fetched_at):
    """Populate keys the cache has no entry for. -> the timestamp to schedule from.

    Without this, adding a widget means its tile reads empty for up to
    REFRESH_INTERVAL (a full day): load_cache() seeds every key from the cached
    payload, and a key absent from that payload stays {} until the next daily tick,
    which is scheduled from the EXISTING cache timestamp. Only missing keys are
    fetched, so this costs nothing for services already cached and will not wake the
    socket-activated ones on every restart.

    The original timestamp is preserved when there was one, so backfilling a single
    new widget does not push the whole daily refresh back by a day. On a cold cache
    everything is missing, so this IS the first full fetch and dates from now —
    which also stops refresh() from immediately repeating it.
    """
    missing = [k for k, v in stats.items() if not v]
    if not missing:
        return fetched_at
    print(f"backfilling: {', '.join(missing)}", file=sys.stderr)
    for key in missing:
        fn = FETCHERS.get(key)
        if fn:
            fn()
    ts = fetched_at or time.time()
    save_cache(ts)
    return ts


def refresh(initial_fetched_at):
    # Runs in the refresh thread, not at startup, so the HTTP listener comes up
    # immediately serving cached data rather than blocking on a cold-cache fetch.
    last_fetched = backfill_missing(initial_fetched_at)
    while True:
        next_due = last_fetched + REFRESH_INTERVAL
        now = time.time()
        wait = max(0, next_due - now)
        if wait:
            time.sleep(wait)
        try:
            for fn in FETCHERS.values():
                fn()
            last_fetched = time.time()
            save_cache(last_fetched)
        except Exception as e:
            print(f"refresh error: {e}", file=sys.stderr)
            # Retry in 1 hour on failure rather than waiting another full day.
            last_fetched = time.time() - REFRESH_INTERVAL + 3600


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # One branch per service used to be spelled out here, which meant adding a
        # widget touched three places. The stats dict already knows every key, so
        # route straight off it; anything else (including /) serves the whole payload.
        key = self.path.strip("/")
        with stats_lock:
            if key in stats:
                data = dict(stats[key])
            else:
                data = {k: dict(v) for k, v in stats.items()}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    # Load cache synchronously before serving so a restart never returns
    # an empty payload while waiting on the daily refresh.
    initial_fetched_at = load_cache()
    threading.Thread(target=refresh, args=(initial_fetched_at,), daemon=True).start()
    http.server.HTTPServer(("127.0.0.1", 8087), Handler).serve_forever()
