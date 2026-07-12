#!/usr/bin/env python3
"""Tiny stats aggregation API for homepage-dashboard widgets.

Aggregates data from multiple service APIs into simple JSON endpoints,
refreshed once per day. Serves on 127.0.0.1:8087.

Endpoints:
  /          — all stats
  /sure      — Sure (accounts, transactions, net worth)
  /openwebui — Open WebUI (models, chats, messages)
  /immich    — Immich (photos, videos, storage)
  /karakeep  — Karakeep (bookmarks, favorites, archived, tags) — direct read-only SQLite
  /homeassistant — Home Assistant (people home, lights on, switches on) — /api/states
  /papra     — Papra (documents, tags, storage) — direct read-only SQLite
  /reactiveresume — Reactive Resume (resumes, users, views) — direct Postgres query
  /grampsweb — Gramps Web (people, families, events) — direct read-only SQLite, summed across trees
  /vaultwarden — Vaultwarden (items, users, devices) — direct read-only SQLite
  /wakapi    — Wakapi (heartbeats, languages, users) — direct read-only SQLite
  /dawarich  — Dawarich (points, trips, visits) — direct Postgres query (superuser)
  /airtrail  — AirTrail (flights, countries, hours) — direct Postgres query (superuser)
  /forgejo   — Forgejo (repositories, open issues, open PRs) — direct Postgres query (superuser)
  /beaverhabits — BeaverHabits (habits, done today, check-ins) — direct read-only SQLite (JSON blob)

Refresh cadence: 86400s (daily). Sure is socket-activated (rpi5/sure.nix)
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
# idle-sleep (rpi5/karakeep.nix) is preserved. -readonly avoids creating
# root-owned -wal/-shm files that would break karakeep (runs as the karakeep user).
KARAKEEP_DB = "/var/lib/karakeep/db.db"
# Same direct-DB-read trick for Papra (rpi5/papra.nix) and Gramps Web
# (rpi5/gramps-web.nix) — both socket-activated, both read read-only so polling
# never wakes them.
PAPRA_DB = "/var/lib/papra/db.sqlite"
GRAMPS_TREES_GLOB = "/var/lib/gramps-web/data/grampsdb/*/sqlite.db"
# Reactive Resume's Postgres role/db (rpi5/reactive-resume.nix, shared cluster).
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
# BeaverHabits (rpi5/beaverhabits.nix): the whole habit list is one JSON blob per
# user in habit_list.data — read-only, so polling never wakes the idle service.
BEAVERHABITS_DB = "/var/lib/beaverhabits/habits.db"
# Dawarich, AirTrail, Forgejo: queried as the postgres superuser over the
# local Unix socket (peer auth via `runuser -u postgres`) rather than each
# app's own role. Simpler than the Reactive Resume password dance above —
# no agenix secret needed — and works regardless of whether the app itself
# authenticates via password (dawarich/airtrail) or peer auth on a Unix
# socket (forgejo, which has no TCP/password role at all).
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/homepage-stats")
STATE_FILE = os.path.join(STATE_DIR, "stats.json")
REFRESH_INTERVAL = 86400  # seconds — see module docstring

stats = {
    "sure": {}, "openwebui": {}, "immich": {}, "karakeep": {}, "homeassistant": {},
    "papra": {}, "reactiveresume": {}, "grampsweb": {},
    "vaultwarden": {}, "wakapi": {}, "dawarich": {}, "airtrail": {}, "forgejo": {},
    "beaverhabits": {},
}
stats_lock = threading.Lock()


def fetch_sure():
    try:
        env = open(ENV_FILE).read()
        key = [l.split("=", 1)[1].strip() for l in env.strip().split("\n") if "SURE_KEY" in l][0]
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
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        print(f"cache save failed: {e}", file=sys.stderr)


def fetch_immich():
    try:
        env = open(ENV_FILE).read()
        key = [l.split("=", 1)[1].strip() for l in env.strip().split("\n") if "IMMICH_KEY" in l][0]
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
                "archived":  count("SELECT COUNT(*) FROM bookmarks WHERE archived = 1;"),
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
    # Multi-tree (rpi5/gramps-web.nix tree = "*"): sum counts across every
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
    def count(sql):
        return int(subprocess.check_output(
            [SQLITE, "-readonly", WAKAPI_DB, sql]
        ).decode().strip() or 0)
    try:
        with stats_lock:
            stats["wakapi"] = {
                "heartbeats": count("SELECT COUNT(*) FROM heartbeats;"),
                "languages":  count("SELECT COUNT(DISTINCT language) FROM heartbeats WHERE language IS NOT NULL AND language != '';"),
                "users":      count("SELECT COUNT(*) FROM users;"),
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
    try:
        with stats_lock:
            stats["airtrail"] = {
                "flights":   int(pg_superuser_query("airtrail", "SELECT COUNT(*) FROM flight;") or 0),
                "countries": int(pg_superuser_query("airtrail", "SELECT COUNT(*) FROM visited_country;") or 0),
                "hours":     round(int(pg_superuser_query("airtrail", "SELECT COALESCE(SUM(duration),0) FROM flight;") or 0) / 60),
            }
    except Exception as e:
        with stats_lock:
            stats["airtrail"]["error"] = str(e)


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
        env = open(ENV_FILE).read()
        token = [l.split("=", 1)[1].strip() for l in env.strip().split("\n") if "HA_TOKEN" in l][0]
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


def refresh(initial_fetched_at):
    last_fetched = initial_fetched_at
    while True:
        next_due = last_fetched + REFRESH_INTERVAL
        now = time.time()
        wait = max(0, next_due - now)
        if wait:
            time.sleep(wait)
        try:
            fetch_sure()
            fetch_openwebui()
            fetch_immich()
            fetch_karakeep()
            fetch_homeassistant()
            fetch_papra()
            fetch_reactive_resume()
            fetch_gramps_web()
            fetch_vaultwarden()
            fetch_wakapi()
            fetch_dawarich()
            fetch_airtrail()
            fetch_forgejo()
            fetch_beaverhabits()
            last_fetched = time.time()
            save_cache(last_fetched)
        except Exception as e:
            print(f"refresh error: {e}", file=sys.stderr)
            # Retry in 1 hour on failure rather than waiting another full day.
            last_fetched = time.time() - REFRESH_INTERVAL + 3600


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with stats_lock:
            if self.path == "/sure":
                data = dict(stats["sure"])
            elif self.path == "/openwebui":
                data = dict(stats["openwebui"])
            elif self.path == "/immich":
                data = dict(stats["immich"])
            elif self.path == "/karakeep":
                data = dict(stats["karakeep"])
            elif self.path == "/homeassistant":
                data = dict(stats["homeassistant"])
            elif self.path == "/papra":
                data = dict(stats["papra"])
            elif self.path == "/reactiveresume":
                data = dict(stats["reactiveresume"])
            elif self.path == "/grampsweb":
                data = dict(stats["grampsweb"])
            elif self.path == "/vaultwarden":
                data = dict(stats["vaultwarden"])
            elif self.path == "/wakapi":
                data = dict(stats["wakapi"])
            elif self.path == "/dawarich":
                data = dict(stats["dawarich"])
            elif self.path == "/airtrail":
                data = dict(stats["airtrail"])
            elif self.path == "/forgejo":
                data = dict(stats["forgejo"])
            elif self.path == "/beaverhabits":
                data = dict(stats["beaverhabits"])
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
