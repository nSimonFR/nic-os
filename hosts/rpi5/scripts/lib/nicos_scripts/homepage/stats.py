#!/usr/bin/env python3
"""Tiny stats aggregation API for homepage-dashboard widgets.

Aggregates data from multiple service APIs into simple JSON endpoints,
refreshed once per day. Serves on 127.0.0.1:8087.

Endpoints (one per homepage tile, three stats each):
  /          — all stats
  /sure      — Sure (cash + spendable, spend + budget left, food + food left) — direct Postgres
  /wealthfolio — Wealthfolio (net worth + investments, invested + gain, 30-day return)
  /immich    — Immich (photos, videos, storage)
  /nextcloud — Nextcloud (files, contacts, storage used) — serverinfo OCS API + Postgres
  /calino    — Calino (events today, events next 7 days, tasks due) — Nextcloud CalDAV
  /affine    — AFFiNE (docs, docs edited in 7 days, storage) — direct Postgres, summed across workspaces
  /beszel    — Beszel (up, triggered alerts, peak CPU temperature in 24h) — direct read-only SQLite
  /karakeep  — Karakeep (bookmarks, untagged, tags) — direct read-only SQLite
  /homeassistant — Home Assistant (last reported day, 30-day cost, heating today)
                   — recorder SQLite for the Linky statistics, /api/states for Voltalis
  /papra     — Papra (documents, tags, storage) — direct read-only SQLite
  /reactiveresume — Reactive Resume (resumes, public, edited in 30 days) — direct Postgres query
  /grampsweb — Gramps Web (people, families, events) — direct read-only SQLite, summed across trees
  /vaultwarden — Vaultwarden (items, changed in 30 days, devices) — direct read-only SQLite
  /wakapi    — Wakapi (coding hours: today, 30 days, all time) — direct read-only SQLite
  /dawarich  — Dawarich (points in 7 days, trips, visits) — direct Postgres query (superuser)
  /airtrail  — AirTrail (flights, countries, hours) — direct Postgres query (superuser)
  /forgejo   — Forgejo (repositories, overdue mirrors, disk size) — direct Postgres query (superuser)
  /beaverhabits — BeaverHabits (habits, done today, check-ins) — direct read-only SQLite (JSON blob)
  /ryot      — Ryot (media seen, hours seen, workouts) — direct Postgres query (superuser)
  /aperture  — Aperture (tokens/day, requests/day, cache-read share) — Prometheus /metrics

A NOTE ON WHAT BELONGS ON A TILE. Three of these used to spend a field on a
number that cannot change: Nextcloud's `users` (1 on a single-user server),
Vaultwarden's `users` (2), AFFiNE's `workspaces` (4), Beszel's `systems` (2) —
and three more on a number that is structurally 0: Nextcloud's `shares`,
Forgejo's `issues`/`pulls` (167 repos, all mirrors), Reactive Resume's `views`.
A dashboard field earns its third of a tile by being able to tell you something
you did not already know, so each of those was replaced by a figure with a time
window or a threshold in it. `alerts` is the shape to copy: 0 nearly always, and
the one day it is not, that is the whole point.

Every homepage tile reads its stats from here rather than from the app itself,
including the three that have a native homepage widget (Nextcloud, AFFiNE,
Beszel). Native widgets cannot be rate-limited from homepage's config, and
homepage's `customapi` widget defaults to refreshInterval = 10s — so the AFFiNE
tile used to POST a GraphQL query at AFFiNE every 10 seconds. Routing everything
through here means one fetch per day per service, and no API key or password
sitting in the dashboard config.

Refresh cadence: 86400s (daily). The stats are written to disk after each
refresh so a service restart preserves the last good values rather than serving
an empty payload until the next nightly refresh.

Sure used to be the exception here: socket-activated with a 600s idle timer, and
its fetcher called the REST API, so the daily poll woke Puma for ten minutes to
read three numbers. It reads Postgres now like the rest, so nothing wakes it.

Papra, Reactive Resume, Gramps Web, Vaultwarden, Wakapi, Dawarich, AirTrail
and Forgejo are also socket-activated (except Dawarich, which is always-on),
and their stats likewise come from reading their database directly
(SQLite, or Postgres as the postgres superuser via peer auth) rather than
their HTTP API, so polling never wakes them at all and no per-app API key or
role password is needed.

AFFiNE reads its database for the second reason: it is always-on, so waking was
never the concern, but the API token its fetcher used no longer exists in AFFiNE
0.27.3 and cannot be re-minted. A credential that can expire under you is a
liability for a dashboard number — see fetch_affine.

State file: $STATE_DIRECTORY/stats.json (set by systemd StateDirectory=).
Falls back to /var/lib/homepage-stats/stats.json if not in a unit.

Every fetcher takes `(cfg, run)`: `cfg` carries the paths (so no path is baked
into the module any more) and `run` executes one command — the seam the tests
substitute, which is what makes 20 fetchers checkable without the services they
read from.
"""

import datetime
import glob
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass

from .. import state
from ..secrets import env_int, env_str

DEFAULT_STATE_DIR = "/var/lib/homepage-stats"
REFRESH_INTERVAL = 86400  # seconds — see module docstring
RETRY_INTERVAL = 60  # seconds; one more go at a key that came back empty

# Bump whenever a fetcher changes WHICH fields it reports (renaming wakapi's
# heartbeats→today, say) — or what an existing field MEANS, which is just as stale a
# cache even though the shape still validates. backfill_missing only re-fetches keys
# that are entirely absent, so without this the old value survives until the next daily
# refresh, up to 24h after the rebuild that changed it: schema 12 is calino's `tasks`
# going from "every open task" (76) to "pending, dated and due" (5), which would
# otherwise have sat there reading 76 under a "Tasks due" label.
#
# 13 replaces home assistant's people_home/lights_on/switches_on with day/cost/heating
# — all three field names change at once, so without a bump every one of them renders
# as NaN until the next nightly refresh.
#
# 14 retires the constant and structurally-zero fields (see the module docstring):
# nextcloud users/shares → contacts/storage, vaultwarden users → changed_30d,
# affine workspaces → edited_7d, beszel systems → peak_temp, karakeep favorites →
# untagged, forgejo issues/pulls → stale_mirrors/size, reactiveresume users/views →
# public/edited_30d, dawarich points → points over 7 days (same NAME, different
# meaning — exactly the case the paragraph above says to bump for), and drops
# showmycards' `locations`, which no tile ever mapped.
STATS_SCHEMA = 14


@dataclass(frozen=True)
class Config:
    # Binaries (overridable so a test — or another host — can point elsewhere).
    curl: str = "curl"
    sqlite: str = "sqlite3"
    psql: str = "psql"
    runuser: str = "runuser"

    env_file: str = "/run/homepage-dashboard/env"

    # Read karakeep's SQLite directly (read-only) instead of its HTTP API: no API
    # key needed, and — crucially — it never wakes karakeep, so the socket-activated
    # idle-sleep (hosts/rpi5/karakeep.nix) is preserved. -readonly avoids creating
    # root-owned -wal/-shm files that would break karakeep (runs as the karakeep user).
    karakeep_db: str = "/var/lib/karakeep/db.db"
    # Same direct-DB-read trick for Papra (hosts/rpi5/papra.nix) and Gramps Web
    # (hosts/rpi5/gramps-web.nix) — both socket-activated, both read read-only so polling
    # never wakes them.
    papra_db: str = "/var/lib/papra/db.sqlite"
    gramps_trees_glob: str = "/var/lib/gramps-web/data/grampsdb/*/sqlite.db"
    # Vaultwarden and Wakapi: same direct-SQLite-read trick as Papra/Karakeep above.
    vaultwarden_db: str = "/var/lib/vaultwarden/db.sqlite3"
    wakapi_db: str = "/var/lib/wakapi/wakapi.db"
    # Beszel's PocketBase database (hosts/rpi5/monitoring.nix). DynamicUser + StateDirectory
    # puts it under /var/lib/private, which is 0700 root — this service runs as root, so
    # the same read-only-SQLite trick applies. Reading it here replaces the native beszel
    # widget, which needed a superuser password in plaintext in the tile config.
    beszel_db: str = "/var/lib/private/beszel-hub/beszel_data/data.db"
    # BeaverHabits (hosts/rpi5/beaverhabits.nix): the whole habit list is one JSON blob per
    # user in habit_list.data — read-only, so polling never wakes the idle service.
    beaverhabits_db: str = "/var/lib/beaverhabits/habits.db"
    # ShowMyCards (hosts/rpi5/showmycards.nix): socket-activated with a 600s idle timer, so
    # the same read-only-SQLite trick applies — its HTTP API is the ONLY thing that can
    # wake it, and a widget polling :8330 would pin both processes awake permanently on
    # a 3.9 GB box. The DB is 0750 showmycards:showmycards; this service runs as root.
    # Lives on /mnt/data, never / (the catalogue is ~0.9 GB).
    showmycards_db: str = "/mnt/data/showmycards/database.db"

    # Reactive Resume's Postgres role/db (hosts/rpi5/reactive-resume.nix, shared cluster).
    # pg_hba requires scram-sha-256 for this role (see pg_hba_file_rules), so the
    # password is read from the same agenix secret reactive-resume-env uses; root
    # can read it despite owner=postgres (root bypasses file permission bits).
    # Postgres isn't part of the socket-activated tier, so querying it never wakes
    # the reactive-resume Node service either.
    rxresume_db: str = "reactive_resume"
    rxresume_role: str = "reactive_resume"
    rxresume_pw_file: str = "/run/agenix/reactive-resume-db-password"

    # AFFiNE's own Postgres (hosts/rpi5/affine.nix). Read as the postgres superuser
    # over the Unix socket, same as forgejo/dawarich — AFFiNE connects over that
    # socket with no password role of its own.
    affine_db: str = "affine"

    # Nextcloud (hosts/rpi5/nextcloud.nix) is the one tile left that genuinely needs
    # an HTTP API; it's always-on, so the daily poll wakes nothing.
    nextcloud_info_url: str = (
        "http://127.0.0.1:8091/ocs/v2.php/apps/serverinfo/api/v1/info?format=json")
    # serverinfo reports num_files and num_shares but nothing per-window and no
    # contact count, so the two figures that replaced `users`/`shares` come from
    # Nextcloud's Postgres instead (same superuser-over-peer route as forgejo).
    # Both sources are read in one fetch; Nextcloud is always-on, so neither wakes
    # anything.
    nextcloud_db: str = "nextcloud_production"
    # Calino (hosts/rpi5/calino.nix) stores nothing of its own — the calendars it
    # renders are Nextcloud's — so its tile reads Nextcloud's CalDAV. Same always-on
    # backend as nextcloud_info_url, and no Host header is needed: overwritecondaddr
    # matches 127.0.0.1 unconditionally, so NC builds its own hrefs regardless.
    nextcloud_dav_url: str = "http://127.0.0.1:8091/remote.php/dav"
    nextcloud_user: str = "nsimon"
    # Calino syncs its OWN settings as a VEVENT in a calendar of its own
    # (docs/CALINOSETTINGSSYNC.md). It is a real CalDAV calendar advertising VEVENT,
    # so nothing in the protocol distinguishes it from a diary — it has to be skipped
    # by name or the tile counts the app's settings blob as an appointment.
    calino_settings_uri: str = "calino-settings"
    sure_url: str = "http://127.0.0.1:13334/sure"
    # The app's own bind, not the read-only :3700 vhost — see fetch_wealthfolio.
    wealthfolio_url: str = "http://127.0.0.1:13345"
    # Cost basis is not exposed by any endpoint, only by this table. Read-only,
    # and this service runs as root so the 0700 state dir is reachable.
    wealthfolio_db: str = "/var/lib/wealthfolio/wealthfolio.db"
    immich_url: str = "http://127.0.0.1:2283"
    hass_url: str = "http://127.0.0.1:8123"
    # Home Assistant's recorder database (hosts/rpi5/home-assistant.nix). The tile
    # needs LONG-TERM STATISTICS — ha-linky's hourly Enedis backfill — and those are
    # not on the REST API at all, only on the websocket one. Read-only, and this
    # service runs as root so hass's 0700 state dir is reachable, same as
    # wealthfolio_db. HA is always-on, so nothing here is about avoiding a wake.
    hass_db: str = "/var/lib/hass/home-assistant_v2.db"

    # Aperture's Prometheus endpoint (hosts/rpi5/aperture-sync.nix grants
    # `read_metrics` to nSimonFR@github; without it this 403s, and `admin` does
    # NOT imply it). Aperture is a Tailscale-managed service on the tailnet, not a
    # unit on this host — it is the one tile whose data comes from off-box, which
    # is also why it has no `nic.services` entry and rides `nic.externalTiles`.
    aperture_metrics_url: str = "http://ai.gate-mintaka.ts.net/metrics"

    state_dir: str = DEFAULT_STATE_DIR
    port: int = 8087
    refresh_interval: int = REFRESH_INTERVAL

    @classmethod
    def from_env(cls, env=None):
        def s(name, default):
            return env_str(name, default, env)

        return cls(
            curl=s("CURL_BIN", "curl"),
            sqlite=s("SQLITE_BIN", "sqlite3"),
            psql=s("PSQL_BIN", "psql"),
            runuser=s("RUNUSER_BIN", "runuser"),
            env_file=s("HOMEPAGE_ENV_FILE", "/run/homepage-dashboard/env"),
            karakeep_db=s("KARAKEEP_DB", cls.karakeep_db),
            papra_db=s("PAPRA_DB", cls.papra_db),
            gramps_trees_glob=s("GRAMPS_TREES_GLOB", cls.gramps_trees_glob),
            vaultwarden_db=s("VAULTWARDEN_DB", cls.vaultwarden_db),
            wakapi_db=s("WAKAPI_DB", cls.wakapi_db),
            beszel_db=s("BESZEL_DB", cls.beszel_db),
            beaverhabits_db=s("BEAVERHABITS_DB", cls.beaverhabits_db),
            showmycards_db=s("SHOWMYCARDS_DB", cls.showmycards_db),
            rxresume_db=s("RXRESUME_DB", cls.rxresume_db),
            rxresume_role=s("RXRESUME_ROLE", cls.rxresume_role),
            rxresume_pw_file=s("RXRESUME_PW_FILE", cls.rxresume_pw_file),
            affine_db=s("AFFINE_DB", cls.affine_db),
            hass_db=s("HASS_DB", cls.hass_db),
            nextcloud_info_url=s("NEXTCLOUD_INFO_URL", cls.nextcloud_info_url),
            nextcloud_db=s("NEXTCLOUD_DB", cls.nextcloud_db),
            nextcloud_dav_url=s("NEXTCLOUD_DAV_URL", cls.nextcloud_dav_url),
            nextcloud_user=s("NEXTCLOUD_USER", cls.nextcloud_user),
            aperture_metrics_url=s("APERTURE_METRICS_URL", cls.aperture_metrics_url),
            calino_settings_uri=s("CALINO_SETTINGS_URI", cls.calino_settings_uri),
            # STATE_DIRECTORY is set by systemd StateDirectory=.
            state_dir=s("STATE_DIRECTORY", DEFAULT_STATE_DIR),
            port=env_int("HOMEPAGE_STATS_PORT", 8087, env),
            refresh_interval=env_int("REFRESH_INTERVAL", REFRESH_INTERVAL, env),
        )

    @property
    def state_file(self):
        return os.path.join(self.state_dir, "stats.json")


def shell_runner(argv, env=None):
    """The production `run`: execute a command, return its stdout as text."""
    return subprocess.check_output(argv, env=env).decode()


class Stats:
    """The published payload. Was a module-level dict plus a bare lock."""

    KEYS = (
        "sure", "wealthfolio", "immich", "karakeep", "homeassistant",
        "papra", "reactiveresume", "grampsweb",
        "vaultwarden", "wakapi", "dawarich", "airtrail", "forgejo",
        "beaverhabits", "ryot", "showmycards",
        "nextcloud", "calino", "affine", "beszel",
        "freereps", "aperture",
    )

    def __init__(self):
        self._lock = threading.Lock()
        self._data = {k: {} for k in self.KEYS}

    def set(self, key, value):
        with self._lock:
            self._data[key] = dict(value)

    def error(self, key, message):
        # Merged INTO the existing entry, not replacing it: a failed refresh keeps
        # serving the last good numbers and adds an `error` field beside them.
        with self._lock:
            self._data[key]["error"] = message

    def get(self, key):
        with self._lock:
            return dict(self._data[key])

    def snapshot(self):
        with self._lock:
            return {k: dict(v) for k, v in self._data.items()}

    def replace_all(self, payload):
        with self._lock:
            for k in self._data:
                self._data[k] = dict(payload.get(k, {}))

    def missing(self):
        """Keys with no usable values — empty, or carrying only an error.

        An errored key counts as missing. It used to not, and the consequence
        was a tile frozen for 24h: a fetcher that failed once (wealthfolio
        losing a race with its own service restart, say) wrote {"error": ...}
        into the cache, which is truthy, so backfill skipped it and the daily
        tick was the next attempt. Three times that needed clearing by hand.
        """
        with self._lock:
            return [k for k, v in self._data.items()
                    if not v or set(v) == {"error"}]

    def __contains__(self, key):
        return key in self._data


def env_var(cfg, name):
    """Read a HOMEPAGE_VAR_* value out of the env file homepage-dashboard shares.

    Written by the homepage-dashboard-env oneshot (hosts/rpi5/homepage.nix), so the
    secrets live in exactly one place for both the dashboard and this aggregator.
    """
    with open(cfg.env_file) as f:
        for line in f:
            if name in line:
                return line.split("=", 1)[1].strip()
    raise KeyError(f"{name} not in {cfg.env_file}")


# ── helpers shared by the fetchers ────────────────────────────────────────────

def sqlite_scalar(cfg, run, db, sql):
    """One read-only scalar out of a SQLite database."""
    return run([cfg.sqlite, "-readonly", db, sql]).strip()


def sqlite_count(cfg, run, db, sql):
    return int(sqlite_scalar(cfg, run, db, sql) or 0)


def pg_superuser(cfg, run, db, sql):
    # postgres superuser via peer auth on the local Unix socket — works for
    # any DB regardless of the app's own auth (password role or, like
    # forgejo, peer-only with no password role at all). Read-only SELECTs.
    return run([cfg.runuser, "-u", "postgres", "--", cfg.psql, "-d", db, "-tAc", sql]).strip()


def curl_json(cfg, run, *args):
    return json.loads(run([cfg.curl, "-sf", *args]))


def curl_text(cfg, run, *args):
    """Raw body, for the one endpoint here that is not JSON — Prometheus text."""
    return run([cfg.curl, "-sf", *args])


def compact(n):
    """A large count at tile width: 865_900_000 -> "866M", 15_641 -> "15.6k".

    Token counts run to nine figures, and homepage's `number` formatter would
    render that as "865,900,000" — wider than the tile. Thousands keep one
    decimal because the interesting range for requests-per-day is 1–20k, where
    "1k" and "1.9k" are meaningfully different; millions do not, because nobody
    reads the tenth of a million.
    """
    n = float(n)
    if abs(n) >= 1_000_000:
        return f"{n / 1_000_000:,.0f}M"
    if abs(n) >= 1_000:
        return f"{n / 1_000:,.1f}k"
    return f"{n:,.0f}"


# ── fetchers ─────────────────────────────────────────────────────────────────

def fetch_sure(cfg, run):
    """This month against its budget, spendable cash, and activity.

    Everything comes from Postgres now, which changed the shape of this fetcher
    for the better: it used to call /api/v1/accounts and /api/v1/transactions,
    and Sure is socket-activated with a 600s idle timer, so the daily poll woke
    Puma for ten minutes to read three numbers. Reading the database directly
    means it never wakes at all — the same trick papra/karakeep/vaultwarden
    already use — and no SURE_KEY is needed.

    Net worth is deliberately absent: it moved to the Wealthfolio tile, which
    is the thing that models the flat and the mortgage and is therefore the
    only place the number is complete.
    """
    spend = pg_superuser(cfg, run, "sure_production", """
        SELECT COALESCE(round(sum(e.amount)::numeric, 2), 0)
        FROM entries e
        JOIN transactions t ON t.id = e.entryable_id AND e.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = e.account_id
        WHERE e.date >= date_trunc('month', CURRENT_DATE)
          AND e.amount > 0 AND t.kind = 'standard' AND a.status <> 'draft'
    """)
    budget = pg_superuser(cfg, run, "sure_production", """
        SELECT COALESCE(budgeted_spending, 0) FROM budgets
        WHERE start_date <= CURRENT_DATE AND end_date >= CURRENT_DATE
        ORDER BY start_date DESC LIMIT 1
    """)
    # Spendable cash: depositories only. Credit cards are liabilities and
    # investment/crypto accounts are not cash, so neither belongs in "what is
    # left to spend".
    #
    # The bracketed half excludes the Livret A, which is nearly all of the
    # balance (EUR 6,400 of EUR 6,716) and is savings rather than money to
    # spend this month — so the headline figure flatters what is actually
    # available. Matched on name because Sure has no "savings" flag on a
    # depository.
    cash = pg_superuser(cfg, run, "sure_production", """
        SELECT COALESCE(round(sum(balance)::numeric, 2), 0) || '|' ||
               COALESCE(round(sum(balance) FILTER (
                 WHERE name NOT ILIKE '%livret%')::numeric, 2), 0)
        FROM accounts
        WHERE accountable_type = 'Depository' AND status <> 'draft'
    """)
    # The food envelope, and what has gone from it. Sure budgets on the parent
    # category and books spend against its children, so both levels count.
    food = pg_superuser(cfg, run, "sure_production", """
        WITH food AS (
          SELECT id FROM categories WHERE name = '0 - Food'
          UNION SELECT id FROM categories
                WHERE parent_id IN (SELECT id FROM categories WHERE name = '0 - Food')
        )
        SELECT COALESCE((SELECT round(bc.budgeted_spending::numeric, 2)
                         FROM budget_categories bc
                         JOIN budgets b ON b.id = bc.budget_id
                         JOIN categories c ON c.id = bc.category_id
                         WHERE c.name = '0 - Food'
                           AND b.start_date <= CURRENT_DATE AND b.end_date >= CURRENT_DATE
                         LIMIT 1), 0) || '|' ||
               COALESCE((SELECT round(sum(e.amount)::numeric, 2)
                         FROM entries e
                         JOIN transactions t ON t.id = e.entryable_id
                                            AND e.entryable_type = 'Transaction'
                         JOIN accounts a ON a.id = e.account_id
                         WHERE e.date >= date_trunc('month', CURRENT_DATE)
                           AND e.amount > 0 AND t.kind = 'standard'
                           AND a.status <> 'draft'
                           AND t.category_id IN (SELECT id FROM food)), 0)
    """)
    spend_eur = round(float(spend or 0))
    budget_eur = round(float(budget or 0))
    cash_total, cash_spendable = (float(x) for x in (cash or "0|0").split("|"))
    food_budget, food_spend = (float(x) for x in (food or "0|0").split("|"))
    # What is left of the month's budget, shown in brackets beside it. Same
    # pre-formatted shape as Wealthfolio's gain, for the same reason: homepage
    # renders an additionalField adjacent to the value with no punctuation of
    # its own. The sign carries the meaning — negative is overspent.
    left = budget_eur - spend_eur
    # Every bracketed figure is folded into its value rather than carried as an
    # additionalField: homepage only renders those in `display: list`, and the
    # default block renderer drops them silently.
    return {
        "cash": f"€{cash_total:,.0f} ({eur(cash_spendable, signed=False)})",
        "spend": f"€{spend_eur:,.0f} ({eur(left)})",
        # Same shape as Spent above: what has gone, then what is left of the
        # envelope. Negative once the envelope is blown.
        "food": f"€{food_spend:,.0f} ({eur(food_budget - food_spend)})",
    }


def today():
    return datetime.date.today().isoformat()


def eur(amount, signed=True):
    """A euro amount for the bracketed half of a tile value.

    Sign leads, symbol trails ("+9,783€", "316€) — the main half of the value
    keeps the leading € it has always had; only what is in brackets is written
    the French way round.
    """
    sign = ("+" if amount >= 0 else "-") if signed else ""
    return f"{sign}{abs(amount):,.0f}€"


def days_ago(n):
    return (datetime.date.today() - datetime.timedelta(days=n)).isoformat()


def pct_delta(current, baseline):
    """`current` against `baseline`, for the bracketed half of a tile value.

    Percent rather than an absolute difference because the two sides are not
    always measured over the same number of days — Enedis leaves gaps, so a
    window total can be short simply for want of data. Comparing daily MEANS and
    reporting the change as a percentage is the shape that survives that; see
    fetch_homeassistant.

    An em dash when there is no baseline to divide by: "+100%" against nothing
    reads as a real measurement, and it is not one.
    """
    if not baseline:
        return "—"
    change = (current - baseline) / baseline * 100
    return f"{'+' if change >= 0 else '-'}{abs(change):.0f}%"


def watt_hours(wh):
    """Wh below a kilowatt-hour, kWh above it — a heater tile spans both.

    Summer idle is single-digit Wh and a winter day is five figures, so a fixed
    unit is unreadable at one end or the other whichever one is picked.
    """
    return f"{wh / 1000:,.1f} kWh" if abs(wh) >= 1000 else f"{wh:,.0f} Wh"


def fetch_wealthfolio(cfg, run):
    """Net worth and month-to-date return, from Wealthfolio's own numbers.

    Everything here is what the app computes, not what this script derives.
    That matters most for the month figure: Wealthfolio is running in HOLDINGS
    tracking mode (the accounts are mirrored from Sure, which is balance- not
    trade-tracked), and in that mode it explicitly REFUSES to state a gain
    amount — `summary.amountStatus` comes back "unavailable", because external
    cash flows are inferred from snapshot deltas rather than observed. Deriving
    the amount here anyway gives -€21k for a month that returned +3.75%, since
    a cash transfer out of an account is indistinguishable from a loss. So the
    tile shows the PERCENT, which the app does compute (`returns.valueReturn`),
    and no amount at all.

    Talks to the loopback bind, deliberately: :3700 is the read-only nginx
    vhost, and while every call here is a read, /performance/summary is a POST
    and would have to be re-allowed there for no reason.
    """
    password = env_var(cfg, "WEALTHFOLIO_PASSWORD")
    jar = os.path.join(cfg.state_dir, "wealthfolio-cookies.txt")
    # Session lives in an HttpOnly cookie; there is no bearer-token option.
    run([cfg.curl, "-sf", "-c", jar, "-X", "POST", f"{cfg.wealthfolio_url}/api/v1/auth/login",
         "-H", "Content-Type: application/json",
         "-d", json.dumps({"password": password})])

    net = json.loads(run([cfg.curl, "-sf", "-b", jar,
                          f"{cfg.wealthfolio_url}/api/v1/net-worth",
                          "-H", "Accept: application/json"]))
    perf = json.loads(run([
        cfg.curl, "-sf", "-b", jar, "-X", "POST",
        f"{cfg.wealthfolio_url}/api/v1/performance/summary",
        "-H", "Content-Type: application/json",
        "-d", json.dumps({
            "itemType": "account", "itemId": "TOTAL", "filter": {"type": "all"},
            "startDate": days_ago(30), "endDate": today(),
        }),
    ]))

    assets = float(net.get("assets", {}).get("total") or 0)
    liabilities = float(net.get("liabilities", {}).get("total") or 0)
    # What the positions cost, i.e. the money originally put in. NOT
    # net_contribution, which is the obvious-looking field and is flat ZERO
    # here: contributions are a transaction-mode concept, and these accounts
    # are holdings-tracked. Cost basis is only known for what Sure knew a basis
    # for — the securities — so the ~€940 of crypto contributes market value
    # with no cost, which understates this slightly rather than inventing one.
    #
    # Market value comes from the same row so the gain below is a difference
    # between two numbers calculated on the same date, rather than one from the
    # API and one from the table.
    #
    # The EXISTS clause is not belt-and-braces. Deleting an account in
    # Wealthfolio does NOT cascade to daily_account_valuation: 19 accounts
    # removed during bring-up left 6163 valuation rows behind, which added
    # EUR 23,626 of phantom investment value to every historical date. The app's
    # own queries scope to live accounts and were unaffected; a bare sum over
    # this table is not, and read 57,850 where the truth was 34,224.
    basis_row = sqlite_scalar(cfg, run, cfg.wealthfolio_db, """
        SELECT COALESCE(round(sum(CAST(v.cost_basis_base AS REAL)), 2), 0) || '|' ||
               COALESCE(round(sum(CAST(v.investment_market_value_base AS REAL)), 2), 0) || '|' ||
               COALESCE((SELECT round(sum(CAST(v2.total_value_base AS REAL)), 2)
                         FROM daily_account_valuation v2
                         WHERE EXISTS (SELECT 1 FROM accounts a WHERE a.id = v2.account_id)
                           AND v2.valuation_date = (
                             SELECT max(valuation_date) FROM daily_account_valuation
                             WHERE valuation_date <= date((SELECT max(valuation_date)
                                                           FROM daily_account_valuation), '-30 day'))), 0)
        FROM daily_account_valuation v
        WHERE EXISTS (SELECT 1 FROM accounts a WHERE a.id = v.account_id)
          AND v.valuation_date = (SELECT max(valuation_date) FROM daily_account_valuation)
    """)
    invested, market_value, start_value = (
        float(x) for x in (basis_row or "0|0|0").split("|"))
    # Returned as a PRE-FORMATTED STRING in percentage points ("2.24"), which
    # is not fussiness. homepage's `percent` format is
    # `Intl.NumberFormat({style:"percent"}).format(value / 100)` — it divides by
    # 100 and then the percent style multiplies by 100 again, so it renders the
    # number unchanged at maximumFractionDigits 0. Feeding it the API's 0.0224
    # displayed "0%". `float` keeps decimals but drops trailing zeros (2.20 ->
    # "2.2"), so the only way to guarantee two places is to format here and let
    # the tile render it as text with a "%" suffix.
    value_return = (perf.get("returns") or {}).get("valueReturn")
    # Unrealized gain: what the holdings are worth now against what they cost.
    # This is a POSITION gain, not a 30-day one — the 30-day AMOUNT is the
    # figure the app declines to state (see above), whereas market value minus
    # cost basis is exact and always available. Pre-formatted with its sign and
    # brackets because homepage renders an additionalField next to the value
    # with no punctuation of its own.
    gain = market_value - invested
    # The euro figure beside the percentage is that PERCENTAGE RESTATED, not an
    # independently derived amount: the app's own return applied to the app's
    # own portfolio value 30 days ago. Deriving it instead from the value delta
    # minus inferred flows is what produced -EUR 21k for a month that gained
    # 3.75%, because a transfer out of a cash account is indistinguishable from
    # a loss when flows are inferred rather than observed.
    if value_return is None:
        return_30d = None
    else:
        pct = float(value_return) * 100
        return_30d = f"{pct:.2f}% ({eur(float(value_return) * start_value)})"
    return {
        "net_worth": f"€{assets - liabilities:,.0f} ({eur(market_value, signed=False)})",
        "invested": f"€{invested:,.0f} ({eur(gain)})",
        "return_30d": return_30d,
    }


def fetch_immich(cfg, run):
    key = env_var(cfg, "IMMICH_KEY")
    # Hit the externally-facing port (2283) so the daily fetch goes
    # through the socket-activate proxy, wakes immich-server briefly,
    # then lets it sleep again (same pattern as fetch_sure on :13334).
    data = curl_json(cfg, run, f"{cfg.immich_url}/api/server/statistics",
                     "-H", f"x-api-key: {key}", "-H", "Accept: application/json")
    return {
        "photos": data.get("photos", 0),
        "videos": data.get("videos", 0),
        "usage": data.get("usage", 0),
    }


def fetch_nextcloud(cfg, run):
    # serverinfo's OCS API, authenticated with the NC-Token it was configured with
    # (hosts/rpi5/nextcloud.nix enables the "serverinfo" app for exactly this). Basic auth
    # as nsimon 401s. Replaces the native `nextcloud` homepage widget, which always
    # renders freespace/activeusers/numfiles/numshares and only lets `fields` filter
    # which of them survive.
    #
    # `users` and `shares` used to take two of the three fields and neither could
    # move: this is a single-user server, so activeUsers.last24hours is 1 whenever
    # anything has touched it and 0 otherwise, and nothing is ever shared with
    # anybody — num_shares has been 0 since the day it was installed. What this
    # instance actually is, is the DAV hub behind Calino and the phone's contact
    # sync, so the two replacements are the contact count and the bytes stored.
    data = curl_json(cfg, run, cfg.nextcloud_info_url,
                     "-H", f"NC-Token: {env_var(cfg, 'NEXTCLOUD_PASSWORD')}",
                     "-H", "OCS-APIRequest: true")["ocs"]["data"]
    return {
        "files": data["nextcloud"]["storage"]["num_files"],
        # oc_cards is CardDAV's row-per-vCard table, so this is contacts across
        # every address book. Calendars are deliberately NOT counted here — the
        # Calino tile already answers the calendar question, and with recurrence
        # expansion rather than a raw oc_calendarobjects count.
        "contacts": int(pg_superuser(cfg, run, cfg.nextcloud_db,
                                     "SELECT COUNT(*) FROM oc_cards;") or 0),
        # The filecache row with an empty path IS the storage root, so its `size`
        # is that storage's total. There are three storages here (the user's home,
        # plus the local appdata ones), and only `home::` is the user's data —
        # summing all of them would fold ~1.4 MB of appdata into the figure and,
        # worse, would drift the day another external storage is mounted.
        # serverinfo has no equivalent: it reports `freespace`, which is a fact
        # about the disk (already in the header's resources widget), not about
        # what Nextcloud is holding.
        "storage": int(pg_superuser(cfg, run, cfg.nextcloud_db, """
            SELECT COALESCE(f.size, 0) FROM oc_filecache f
              JOIN oc_storages s ON s.numeric_id = f.storage
             WHERE f.path = '' AND s.id LIKE 'home::%';
        """) or 0),
    }


# ── Calino / CalDAV ───────────────────────────────────────────────────────────
#
# Calino (hosts/rpi5/calino.nix) has no store and no process of its own, so there is
# no database to read and no API to call — its tile has to read the calendars it
# renders, which are Nextcloud's. That means CalDAV, and CalDAV is the reason these
# three numbers are all COUNTS obtained with a server-side filter:
#
# ⚠ DO NOT compute "events today" from `oc_calendarobjects.firstoccurence` /
#   `lastoccurence` in Postgres, which is the obvious tokenless route the other
#   fetchers would suggest. Those two columns bound the whole recurrence SET, so a
#   weekly standup defined in 2019 and running till 2030 has firstoccurence far in
#   the past and lastoccurence far in the future, and `first <= today_end AND last >=
#   today_start` therefore matches it on every day of the decade. Every recurring
#   event would be counted as "today". A CalDAV `time-range` filter makes SabreDAV
#   expand the recurrence properly, which is work this module has no business
#   reimplementing.
#
# Each query asks for `<d:getetag/>` and nothing else, so the response is one line
# per match and the count is the answer — no iCalendar parsing, no timezone maths on
# DTSTART, and none of the `VALUE=DATE` / `TZID=` / post-expand-UTC forms to handle.
# The cost is one request per calendar per window (~27 a day across 11 calendars),
# which is nothing at a daily cadence and never wakes anything: Nextcloud is
# always-on.

DAV = "{DAV:}"
CALDAV = "{urn:ietf:params:xml:ns:caldav}"

_DISCOVER_BODY = (
    '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
    "<d:prop><d:resourcetype/><c:supported-calendar-component-set/></d:prop>"
    "</d:propfind>"
)


def _event_body(start, end):
    return (
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        "<d:prop><d:getetag/></d:prop><c:filter>"
        '<c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">'
        f'<c:time-range start="{start}" end="{end}"/>'
        "</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
    )


# Pending only — STATUS:NEEDS-ACTION, not "everything that is not COMPLETED".
#
# ⚠ That means a VTODO with STATUS:IN-PROCESS, or with no STATUS property at all, is
#   NOT counted. Neither exists on this account (every VTODO in all six lists carries
#   either NEEDS-ACTION or COMPLETED — verified), but a client that starts writing
#   IN-PROCESS would silently undercount. A text-match cannot express OR, so widening
#   means a second query unioned into `pending` below.
_TODO_PENDING_BODY = (
    '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
    "<d:prop><d:getetag/></d:prop><c:filter>"
    '<c:comp-filter name="VCALENDAR"><c:comp-filter name="VTODO">'
    '<c:prop-filter name="STATUS"><c:text-match>NEEDS-ACTION</c:text-match>'
    "</c:prop-filter></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
)



def _todo_filter_body(inner):
    return (
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        "<d:prop><d:getetag/></d:prop><c:filter>"
        '<c:comp-filter name="VCALENDAR"><c:comp-filter name="VTODO">'
        f"{inner}</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
    )


# "Has a date at all". A prop-filter with no children matches when the property is
# DEFINED (RFC 4791 §9.7), and it is unaffected by the time-range bug below because
# there is no time-range in these two. DURATION needs a DTSTART to mean anything, so
# DUE ∪ DTSTART is the whole of "dated".
_TODO_DUE_BODY = _todo_filter_body('<c:prop-filter name="DUE"/>')
_TODO_DTSTART_BODY = _todo_filter_body('<c:prop-filter name="DTSTART"/>')


def _todo_current_body(end):
    """VTODOs overlapping (epoch, end] — used to drop the future-dated ones.

    ⚠ This matches UNDATED VTODOs too: RFC 4791 §9.9 says a VTODO with no DTSTART, DUE
      or DURATION overlaps EVERY time range (verified live — all 11 pending items in
      `Courses`, a shopping list, match). So a time-range alone cannot answer "has a
      date that has arrived"; it has to be intersected with the two prop-filters above.
    """
    return _todo_filter_body(f'<c:time-range start="19700101T000000Z" end="{end}"/>')


def dav_xml(cfg, run, method, url, body, depth="1"):
    """One authenticated DAV request against Nextcloud, parsed as XML.

    Basic auth with the app password the Nextcloud tile already holds as
    HOMEPAGE_VAR_NEXTCLOUD_PASSWORD — serverinfo consumes it as an NC-Token, but it
    is a genuine app password underneath, so it authenticates DAV too and this tile
    needs no second secret. (`env_var` strips nothing: homepage.nix already ran
    `tr -d '\\r\\n'` over the agenix file, whose 73rd byte is a CR. A CR that reaches
    the Authorization header does not 401 — Nextcloud answers
    `PasswordLoginForbidden`, because the token lookup misses and it then treats the
    value as a login password.)
    """
    out = run([
        cfg.curl, "-sf",
        "-u", f"{cfg.nextcloud_user}:{env_var(cfg, 'NEXTCLOUD_PASSWORD')}",
        "-X", method,
        "-H", f"Depth: {depth}",
        "-H", "Content-Type: application/xml",
        "--data", body, url,
    ])
    return ET.fromstring(out)


def dav_hrefs(cfg, run, url, body):
    """The href of every object a calendar-query matched. The filter does the work."""
    root = dav_xml(cfg, run, "REPORT", url, body)
    return {e.findtext(f"{DAV}href") for e in root.iter(f"{DAV}response")}


def dav_count(cfg, run, url, body):
    return len(dav_hrefs(cfg, run, url, body))


def discover_calendars(cfg, run):
    """(event calendars, task calendars) as URLs, split by supported component.

    Splitting matters here: of the 11 calendars on this account only ~5 hold VEVENTs
    and 6 are iCloud task lists, so asking every collection for both would double the
    request count to no purpose.

    The returned URLs are rebuilt from the home URL plus each href's last segment
    rather than from the href itself. Nextcloud emits hrefs under `overwritewebroot`
    (`/nextcloud/remote.php/dav/...`) because overwritecondaddr matches 127.0.0.1
    unconditionally, while this fetcher dials the backend directly at
    `/remote.php/dav` with no such prefix — joining the href to the base would give a
    doubled or missing webroot and 404 every query.

    Two kinds of collection are deliberately dropped:

      * `{DAV:}collection` + `{http://calendarserver.org/ns/}subscribed` — the webcal
        subscriptions (here: TRUSK, Google, Airbnb). They advertise VEVENT and answer
        a calendar-query with 207, but the answer is ALWAYS zero objects: Nextcloud
        does not expose a subscription's cached contents over DAV, the refresh is the
        client's job. Querying them costs requests and can only ever add 0, so their
        events are simply not in these numbers — verified, not assumed.
      * `calino_settings_uri` — see the Config field.
    """
    home = f"{cfg.nextcloud_dav_url}/calendars/{cfg.nextcloud_user}/"
    root = dav_xml(cfg, run, "PROPFIND", home, _DISCOVER_BODY)

    events, tasks = [], []
    for resp in root.iter(f"{DAV}response"):
        href = (resp.findtext(f"{DAV}href") or "").rstrip("/")
        segment = href.rsplit("/", 1)[-1]
        # Skip the home collection itself, and anything that is not a calendar —
        # `inbox`, `outbox` and `trashbin` all answer this PROPFIND too.
        if not segment or segment == cfg.nextcloud_user:
            continue
        if segment == cfg.calino_settings_uri:
            continue
        if resp.find(f".//{CALDAV}calendar") is None:
            continue
        url = f"{home}{segment}/"
        comps = {c.get("name") for c in resp.iter(f"{CALDAV}comp")}
        # An empty set means the server declined to say; CalDAV's default is
        # "everything", so treat it as both rather than silently dropping the
        # calendar from every count.
        if not comps or "VEVENT" in comps:
            events.append(url)
        if not comps or "VTODO" in comps:
            tasks.append(url)
    return events, tasks


def fetch_calino(cfg, run, now=None):
    """Events today, events in the next 7 days, and tasks due.

    "Due" is pending (STATUS:NEEDS-ACTION) AND carrying a DUE/DTSTART AND that date
    already reached. On this account that is 5, out of 76 pending: 21 of the pending are
    future-dated, and 50 are undated list items (`Courses`, `Recettes`, `Cadeaux`,
    `Appartement`, `Dettes` are shopping/gift lists with no dates at all). Only
    `Reminders` contributes. A tile showing 76 says "you have a lot of lists"; this one
    says what is actually owed today.

    Windows are LOCAL days converted to UTC stamps, not `utcnow()`-based: at 20:30
    CEST a UTC-midnight window is already two hours into tomorrow, which would move
    late-evening events onto the wrong day.

    The offset comes from `now.tzinfo`, never from the ambient system zone, so the
    windows are a pure function of the argument and the tests can pin them. Production
    passes nothing and gets `now().astimezone()`, i.e. the host's current offset; that
    fixed offset is then used for all three boundaries, so a DST change inside the
    7-day window puts its far edge an hour out. That is deliberate — an hour of slack
    on the *end* of a week-long window cannot change a count of events, and the
    alternative is resolving a zone name out of /etc/timezone.
    """
    now = now or datetime.datetime.now().astimezone()

    def midnight(day):
        return datetime.datetime.combine(day, datetime.time.min, tzinfo=now.tzinfo)

    def stamp(dt):
        return dt.astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    today = now.date()
    start = stamp(midnight(today))
    end_today = stamp(midnight(today + datetime.timedelta(days=1)))
    end_week = stamp(midnight(today + datetime.timedelta(days=7)))

    event_cals, task_cals = discover_calendars(cfg, run)

    def tasks(url):
        """Pending AND dated AND that date has arrived. Intersected HERE, not server-side.

        ⚠ SabreDAV DROPS a `prop-filter` whenever a `time-range` sits in the same
          comp-filter, so the single query that ought to express this AND silently
          answers the time-range alone. Measured on this server: `Reminders` has 27
          pending and 792 in range, and the combined query returns 792 — every
          COMPLETED task in range, 29× the truth. Element order is not the cause;
          RFC 4791 wants `time-range` first and it behaves identically either way.

        So each condition is a separate server-side filter and the AND is an href
        intersection, which is exact. Ordered cheapest-discriminator-first and
        short-circuited: five of the six lists here are entirely undated, so they cost
        three requests and never reach the time-range.
        """
        pending = dav_hrefs(cfg, run, url, _TODO_PENDING_BODY)
        if not pending:
            return 0
        dated = pending & (dav_hrefs(cfg, run, url, _TODO_DUE_BODY)
                           | dav_hrefs(cfg, run, url, _TODO_DTSTART_BODY))
        if not dated:
            return 0
        return len(dated & dav_hrefs(cfg, run, url, _todo_current_body(stamp(now))))

    return {
        "today": sum(dav_count(cfg, run, url, _event_body(start, end_today))
                     for url in event_cals),
        "week": sum(dav_count(cfg, run, url, _event_body(start, end_week))
                    for url in event_cals),
        "tasks": sum(tasks(url) for url in task_cals),
    }


def fetch_affine(cfg, run):
    # Reads AFFiNE's Postgres, NOT its GraphQL — deliberately tokenless. This used
    # to POST `{ workspaces { blobsSize docs { totalCount } } }` with the `ut_…`
    # Bearer token in HOMEPAGE_VAR_AFFINE_TOKEN, and AFFiNE 0.27.3 removed user
    # access tokens from its API surface altogether (of the token mutations only
    # createMcpCredential survives, and that one is workspace-scoped to AFFiNE's own
    # /mcp endpoint — it cannot authenticate a GraphQL query). Every request 401ed
    # from the 0.27.3 upgrade onward, and because a failed fetcher keeps publishing
    # its last good numbers the tile showed two-day-old counts. There is no token to
    # rotate back in, so the dependency is gone instead.
    #
    # Summed across every workspace: the tile before that read workspaces[0], which
    # is the 3-doc scratch workspace rather than the ~7.5k-doc main one (see
    # project_affine_workspaces_courses).
    def count(sql):
        return int(pg_superuser(cfg, run, cfg.affine_db, sql) or 0)

    return {
        # workspace_pages is AFFiNE's registry of actual docs. `snapshots` holds a
        # few more rows — one Yjs doc per workspace for the doc list itself — which
        # are not docs anyone would count on a dashboard.
        "docs": count("SELECT COUNT(*) FROM workspace_pages;"),
        # Replaces `workspaces`, which was a 4 fixed by the four-workspace layout in
        # project_affine_workspaces_courses and could only change if that layout did.
        # With 7,914 docs the total is effectively a constant too — what says whether
        # the wiki is alive is how many were touched this week (15).
        #
        # The timestamp lives on `snapshots`, not on workspace_pages (which has no
        # mtime at all), so this joins the two: snapshots alone counts 17 because it
        # includes the per-workspace doc-list Yjs docs, the same rows the `docs`
        # count above excludes. Joining keeps both fields counting the same universe.
        "edited_7d": count("""
            SELECT COUNT(*) FROM snapshots s
              JOIN workspace_pages p
                ON p.page_id = s.guid AND p.workspace_id = s.workspace_id
             WHERE s.updated_at > now() - interval '7 days';
        """),
        # deleted_at IS NULL reproduced GraphQL's blobsSize to the byte
        # (558516275); summing every row instead over-reports by the tombstones.
        "storage": count(
            "SELECT COALESCE(SUM(size), 0) FROM blobs WHERE deleted_at IS NULL;"),
    }


# Hottest the CPU has been in the last 24 hours, across every monitored system.
#
# `stats` is a JSON blob per sample and the temperatures live in a nested object
# keyed by sensor name (`{"t": {"cpu_thermal": 61.15, "rp1_adc": 60.7}}`), which
# is why this reads $.t.cpu_thermal by name rather than taking the object's max:
# rp1_adc is the I/O controller, it tracks the SoC closely, and including it would
# make the figure "hottest sensor" instead of "hottest CPU".
#
# type = '10m' rather than '1m': Beszel keeps only about an hour of 1-minute
# samples before rolling them up, so a 24h window over '1m' silently becomes a
# 1h window. json_extract returns NULL on a system whose agent reports no
# temperature at all (beast does not always), and MAX skips NULLs, so a mixed
# fleet still yields the Pi's figure rather than nothing.
BESZEL_PEAK_TEMP_SQL = """
SELECT COALESCE(ROUND(MAX(json_extract(stats, '$.t.cpu_thermal')), 1), 0)
  FROM system_stats
 WHERE type = '10m' AND created > datetime('now', '-1 day');
"""


def fetch_beszel(cfg, run):
    # Read-only direct SQLite query against Beszel's PocketBase DB — same trick as
    # fetch_karakeep. `alerts.triggered` is the interesting one: it's what actually
    # fired, not how many alert rules exist.
    #
    # `systems` was the third field and it is a 2 that has been a 2 since beast was
    # added. Peak CPU temperature replaced it because this is a Pi 5 in a case whose
    # documented failure mode is thermal throttling and OOM-thrash-into-watchdog-
    # reset, and Beszel is already sampling the sensor every minute — the dashboard
    # simply never showed it. `up` still carries the fleet size implicitly: it reads
    # 1 when beast is suspended, which is most of the time and is normal.
    return {
        "up": sqlite_count(cfg, run, cfg.beszel_db,
                           "SELECT COUNT(*) FROM systems WHERE status = 'up';"),
        "alerts": sqlite_count(cfg, run, cfg.beszel_db,
                               "SELECT COUNT(*) FROM alerts WHERE triggered = 1;"),
        "peak_temp": float(sqlite_scalar(cfg, run, cfg.beszel_db,
                                         BESZEL_PEAK_TEMP_SQL) or 0),
    }


def fetch_karakeep(cfg, run):
    # Read-only direct SQLite query — no API key, never wakes karakeep.
    #
    # `favorites` was 0 of 15 bookmarks — the feature is simply not used, so the
    # field could only ever render 0. Untagged is the replacement rather than
    # "added in the last 7 days", which would ALSO be 0 (nothing has been saved
    # here in a month): with 32 tags over 15 bookmarks the collection is
    # over-tagged, not under-tagged, so the count of items the AI tagger has not
    # reached is the one number here that is both non-zero and actionable.
    return {
        "bookmarks": sqlite_count(cfg, run, cfg.karakeep_db, "SELECT COUNT(*) FROM bookmarks;"),
        "untagged": sqlite_count(cfg, run, cfg.karakeep_db, """
            SELECT COUNT(*) FROM bookmarks b
             WHERE NOT EXISTS (SELECT 1 FROM tagsOnBookmarks t WHERE t.bookmarkId = b.id);
        """),
        "tags": sqlite_count(cfg, run, cfg.karakeep_db, "SELECT COUNT(*) FROM bookmarkTags;"),
    }


def fetch_papra(cfg, run):
    # Read-only direct SQLite query — same trick as fetch_karakeep, never wakes papra.
    return {
        "documents": sqlite_count(cfg, run, cfg.papra_db,
                                  "SELECT COUNT(*) FROM documents WHERE is_deleted = 0;"),
        "tags": sqlite_count(cfg, run, cfg.papra_db, "SELECT COUNT(*) FROM tags;"),
        "size": sqlite_count(
            cfg, run, cfg.papra_db,
            "SELECT COALESCE(SUM(original_size),0) FROM documents WHERE is_deleted = 0;"),
    }


def fetch_beaverhabits(cfg, run, today=None):
    # Read-only direct SQLite query — same trick as fetch_papra, never wakes the
    # socket-activated beaverhabits service. The habit list is a compact JSON blob
    # per user in habit_list.data: {"habits":[{name,status,records:[{day,done}]}]}.
    # "archive" status = habit the user retired, so it's excluded from the counts.
    raw = run([cfg.sqlite, "-readonly", cfg.beaverhabits_db, "SELECT data FROM habit_list;"])
    today = today or time.strftime("%Y-%m-%d")
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
    return {"habits": habits, "done_today": done_today, "checkins": checkins}


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


def fetch_showmycards(cfg, run):
    # Read-only direct SQLite query — same trick as fetch_papra, never wakes the
    # socket-activated showmycards pair.
    #
    # `cards` is the 171k-printing Scryfall catalogue, NOT the collection: counting
    # it would report 171182 owned cards. The collection is `inventories`, and a row
    # there is a stack, so cards = SUM(quantity), not COUNT(*).
    #
    # No `locations` key. It used to count storage_locations (8) and no tile ever
    # mapped it — a tile shows three fields and this was a fourth, so the query ran
    # daily to populate a number nothing rendered.
    db = cfg.showmycards_db
    return {
        "cards": sqlite_count(cfg, run, db, "SELECT COALESCE(SUM(quantity),0) FROM inventories;"),
        "decks": sqlite_count(cfg, run, db, "SELECT COUNT(*) FROM lists;"),
        "value": round(float(sqlite_scalar(cfg, run, db, SHOWMYCARDS_VALUE_SQL) or 0), 2),
    }


def fetch_reactive_resume(cfg, run):
    def q(sql):
        with open(cfg.rxresume_pw_file) as fh:
            password = fh.read().strip()
        env = dict(os.environ, PGPASSWORD=password)
        return run([
            cfg.psql, "-h", "127.0.0.1", "-p", "5432",
            "-U", cfg.rxresume_role, "-d", cfg.rxresume_db, "-tAc", sql,
        ], env=env).strip()

    # `users` was 2 and `views` was 0 — a self-hosted resume builder nobody has
    # published a public link from cannot register a view, so two of three fields
    # were fixed.
    return {
        "resumes": int(q("SELECT COUNT(*) FROM resume;") or 0),
        # An AGE, not a count-in-window. A "edited in the last 30 days" field reads
        # 0 here (the newest edit is 2026-07-27, five weeks back) and a 90-day one
        # reads 14 — both are the disease this change is curing, because editing a
        # CV is an every-few-months act and no fixed window fits it. Days since the
        # last edit is never 0-by-construction and answers the real question.
        "updated": int(float(q("""
            SELECT COALESCE(EXTRACT(EPOCH FROM now() - MAX(updated_at)) / 86400, 0)
              FROM resume;
        """) or 0)),
        # is_public stays even though it is 0, and for the same reason beszel's
        # `alerts` stays: it is an ALARM, not a statistic. Nothing here is meant to
        # be on the public internet, so 0 is the reassuring reading and a 1 is
        # something to see immediately. Contrast `views`, which was 0 because the
        # feature is unreachable — that 0 could never carry information.
        "public": int(q("SELECT COUNT(*) FROM resume WHERE is_public = true;") or 0),
    }


def fetch_gramps_web(cfg, run, find=None):
    # Multi-tree (hosts/rpi5/gramps-web.nix tree = "*"): sum counts across every
    # tree's SQLite database rather than assuming a single tree.
    dbs = (find or glob.glob)(cfg.gramps_trees_glob)

    def sum_count(table):
        return sum(sqlite_count(cfg, run, db, f"SELECT COUNT(*) FROM {table};") for db in dbs)

    return {
        "people": sum_count("person"),
        "families": sum_count("family"),
        "events": sum_count("event"),
    }


def fetch_vaultwarden(cfg, run):
    # Read-only direct SQLite query — same trick as fetch_karakeep, never wakes vaultwarden.
    #
    # `users` was 2 and a two-person vault does not gain users. Items changed in the
    # last 30 days replaces it: on a password manager that is the figure that says
    # whether anything is being rotated, and it moves (19 of 793 this month) without
    # being noise.
    db = cfg.vaultwarden_db
    return {
        "items": sqlite_count(cfg, run, db,
                              "SELECT COUNT(*) FROM ciphers WHERE deleted_at IS NULL;"),
        # updated_at is bumped on any edit including a password rotation; created_at
        # rows also satisfy it, which is correct — a new credential is a change too.
        "changed_30d": sqlite_count(cfg, run, db, """
            SELECT COUNT(*) FROM ciphers
             WHERE deleted_at IS NULL AND updated_at > datetime('now', '-30 day');
        """),
        "devices": sqlite_count(cfg, run, db, "SELECT COUNT(*) FROM devices;"),
    }


def fetch_wakapi(cfg, run):
    # Coding time, not row counts: `durations` is wakapi's own precomputed
    # heartbeat-coalescing table (the same thing its summaries are built from), and
    # its `duration` column is NANOSECONDS — hence /3.6e12 for hours.
    #
    # `time` values carry a UTC offset (e.g. "…21:39:51.902+02:00"), so date() on
    # them yields a UTC date; the 'localtime' modifier on both sides makes "today"
    # mean the local day rather than shifting by two hours after midnight.
    def hours(where=""):
        ns = sqlite_count(
            cfg, run, cfg.wakapi_db,
            f"SELECT COALESCE(SUM(duration), 0) FROM durations {where};")
        return round(ns / 3.6e12, 1)

    return {
        "today": hours("WHERE date(time, 'localtime') = date('now', 'localtime')"),
        "last_30d": hours("WHERE time >= datetime('now', '-30 day')"),
        "total": hours(),
    }


def fetch_dawarich(cfg, run):
    """Points over the last 7 days, then trips and visits all-time.

    `points` was an all-time count (7,244) and that is the one number here that
    could not tell you the thing you need to know about this service, which is
    whether the phone is still feeding it. It is barely feeding it: 134 points over
    7 days is ~19 a day, and that sampling rate is precisely why DBSCAN has
    produced no new visit since 2026-04-19 (known_issue_dawarich_no_visits_sparse_
    points). The all-time total hid that behind a large, always-growing figure.

    `visits` stays all-time even though it is the frozen number, because a "visits
    this week" field would read 0 and look like a display bug rather than the
    starvation it is; the 7-day point count is the field that carries the signal,
    and the two sit next to each other on the tile.
    """
    def count(sql):
        return int(pg_superuser(cfg, run, "dawarich", sql) or 0)

    return {
        # `timestamp` is an integer epoch column on points, not a timestamptz.
        "points_7d": count("""
            SELECT COUNT(*) FROM points
             WHERE timestamp > EXTRACT(EPOCH FROM now()) - 7 * 86400;
        """),
        "trips": count("SELECT COUNT(*) FROM trips;"),
        "visits": count("SELECT COUNT(*) FROM visits;"),
    }


def _freereps_yesterday_total(cfg, run, metric):
    """Total of `metric` over the last COMPLETE day.

    Yesterday, not today, and not "the most recent day that happens to have
    data". Both alternatives are worse here:

    * Today is always partial. The aggregator refreshes once every
      REFRESH_INTERVAL (86400s) at whatever wall-clock time the service last
      started, so "today" would be sampled at an arbitrary hour — a fetch at
      06:00 would show a near-empty day and keep showing it for 24 hours.
    * "Most recent day with data" would keep rendering a week-old day as if it
      were current the moment the phone stops syncing. Yesterday reads 0
      instead, which is wrong but VISIBLY wrong — the failure mode
      known_issue_homepage_stats_silent_stale_tiles exists to avoid.

    Summed, not averaged: Apple Health delivers these as intraday buckets (~8
    step_count rows a day), so this is a SUM over the day's buckets. `qty` is the
    column — FreeReps leaves avg_val/min_val/max_val NULL for cumulative metrics
    and fills only qty.

    `source = ''` is pinned, and it is NOT paranoia: health_metrics already holds
    two sources ("" from the Health Auto Export ingest and "FreeReps Backfill"),
    and FreeReps only dedups by source priority in its OWN query layer — a plain
    SUM here sees every source at once. They do not overlap on these metrics
    today, so the filter is a no-op now and a guard against a silently doubled
    step count once something backfills the same days twice.
    """
    return float(pg_superuser(cfg, run, "freereps", f"""
        SELECT COALESCE(SUM(qty), 0)
          FROM health_metrics
         WHERE metric_name = '{metric}'
           AND source = ''
           AND time >= current_date - INTERVAL '1 day'
           AND time <  current_date;
    """) or 0)


def _freereps_month_total(cfg, run, metric):
    """Total of `metric` so far this calendar month, today included.

    Today is deliberately NOT excluded here, unlike _freereps_yesterday_total.
    A month-to-date total is cumulative, so a partial today simply makes it grow
    through the day — that is the expected reading of "this month". For a
    single-day figure a partial day is misleading, which is why that one stops at
    midnight; the two rules differ because the questions differ.

    Same `source = ''` pin and same `qty` column as the day totals — see
    _freereps_yesterday_total for why both matter.
    """
    return float(pg_superuser(cfg, run, "freereps", f"""
        SELECT COALESCE(SUM(qty), 0)
          FROM health_metrics
         WHERE metric_name = '{metric}'
           AND source = ''
           AND time >= date_trunc('month', current_date);
    """) or 0)


def fetch_freereps(cfg, run):
    """Apple Health: this month's distance, yesterday's steps, latest weigh-in.

    Three different time windows on purpose, one per question: distance is a
    month-to-date running total, steps are the last complete day, and weight is
    simply the most recent reading.

    Reads Postgres directly rather than FreeReps' own /api/v1/stats, and that is
    the whole point: freereps.service is socket-activated (0 MB at rest), so a
    daily poll against its HTTP API would wake it every single day and throw
    away the reason it sleeps. Same rule as every other tile here.

    Weight is the odd one out on purpose, twice over. It is NOT a
    yesterday total — weigh-ins are sparse (146 rows across six years, and the
    newest is over a month old), so "yesterday" would render 0 almost every day;
    the last known value is the only useful reading. And it does NOT pin
    `source`, unlike the two day totals: a SUM over several sources
    double-counts, whereas "the most recent row" is correct whichever source
    produced it, and filtering would freeze the tile on the last Apple weight the
    day a Withings sync starts writing `source = 'Withings'`.
    """
    # No time bound on the weight lookup, unlike the averages above. Weight is
    # sparse and can be weeks stale (the live table's newest is over a month old,
    # and a bound would render that as 0 rather than "last known"), and
    # health_metrics is small enough here that the missing-chunk-exclusion cost
    # TimescaleDB warns about is irrelevant at once a day.
    weight = pg_superuser(cfg, run, "freereps", """
        SELECT COALESCE(ROUND(qty::numeric, 1), 0)
          FROM health_metrics
         WHERE metric_name = 'weight_body_mass'
         ORDER BY time DESC
         LIMIT 1;
    """)
    # distance_walking_running is stored in METRES (the units column says "m"),
    # not kilometres: a day's 13960 alongside 18545 steps is ~0.75 m a step,
    # which is a walk, not a marathon. Reporting qty as-is would have put "13960
    # km" on the tile.
    metres = _freereps_month_total(cfg, run, "distance_walking_running")
    return {
        "km": round(metres / 1000, 1),
        "steps": int(_freereps_yesterday_total(cfg, run, "step_count")),
        "weight": float(weight or 0),
    }


def fetch_airtrail(cfg, run):
    # flight.duration is SECONDS, not minutes: the longest flight on record is
    # 42872, i.e. 11h54m. Dividing by 60 reported 7922 "hours" for 29 flights;
    # the real total is 132.
    seconds = int(pg_superuser(
        cfg, run, "airtrail", "SELECT COALESCE(SUM(duration),0) FROM flight;") or 0)
    return {
        "flights": int(pg_superuser(cfg, run, "airtrail",
                                    "SELECT COUNT(*) FROM flight;") or 0),
        "countries": int(pg_superuser(cfg, run, "airtrail",
                                      "SELECT COUNT(*) FROM visited_country;") or 0),
        "hours": round(seconds / 3600),
    }


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


def fetch_ryot(cfg, run):
    # Ryot (hosts/rpi5/ryot.nix) is Postgres-backed. Read its counts directly as the
    # postgres superuser — no API token, and (like the other direct-read tiles)
    # it never touches Ryot's own HTTP layer. Ryot is always-on (not socket-
    # activated), so this is purely to avoid holding an API key on the tile.
    #
    # "seen" counts finished consumption events (each episode of a show is its own
    # row), NOT `metadata`, which is the 16.8k-row metadata catalogue Ryot has
    # fetched from providers and is nothing to do with what was watched.
    return {
        "seen": int(pg_superuser(
            cfg, run, "ryot", "SELECT COUNT(*) FROM seen WHERE state = 'completed';") or 0),
        "hours": round(int(pg_superuser(cfg, run, "ryot", RYOT_MEDIA_HOURS_SQL) or 0) / 60),
        "workouts": int(pg_superuser(cfg, run, "ryot", "SELECT COUNT(*) FROM workout;") or 0),
    }


# ── Aperture ─────────────────────────────────────────────────────────────────
#
# The only tile fed from OFF this host: Aperture is Tailscale-managed at
# ai.gate-mintaka.ts.net (project_aperture_observability), so it has no unit, no
# database here and no `nic.services` entry — it reaches the dashboard through
# `nic.externalTiles` instead.
#
# ⚠ These figures UNDERCOUNT, and the gap is not small. codex-proxy returns zero
#   usage on every response (Vercel AI SDK v6 spec mismatch, vercel/ai#12771), so
#   Aperture is blind to the token cost of all gpt-5.6 traffic while still counting
#   its requests — 663 gpt responses contribute to the request rate and nothing to
#   the token rate. Treat tokens/day as "tokens Anthropic-side", not "all tokens".

# Prometheus exposition format: `name{label="v",...} 1.23e+08`. Values may be in
# scientific notation, which is why the value is parsed as float and not int.
_PROM_LINE = re.compile(r'^(?P<name>[a-z_]+)(?:\{(?P<labels>[^}]*)\})?\s+(?P<value>\S+)$')

# The four token kinds Aperture persists. Its own /metrics HELP text says to add
# them for a total, so that is what this does rather than reading
# aperture_llm_tokens_total{type="input"} — that one already folds cache_read into
# input, and summing the two families would double-count 817M cached tokens.
_TOKEN_TYPES = ("input", "cache_read", "output", "reasoning")

# Below this, do not recompute the rate or move the baseline. The refresh loop
# calls every fetcher once a REFRESH_INTERVAL, so the normal elapsed time here is
# ~24h; a much shorter gap means something restarted the service and re-fetched
# (a schema bump, say), and dividing a few minutes' delta by a few minutes of
# elapsed time turns ordinary noise into a wild per-day figure. Holding the last
# good rate is the honest answer for the rest of the day.
APERTURE_MIN_ELAPSED = 6 * 3600


def parse_prometheus(text):
    """-> {metric_name: {frozenset_of_label_pairs: float}} for the lines we need.

    A deliberately small parser, not a Prometheus client: this reads four counters
    out of a 934-line exposition and has no business handling histograms, exemplars
    or `# TYPE` semantics. Comment lines start with '#' and are skipped.
    """
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _PROM_LINE.match(line)
        if not m:
            continue
        labels = {}
        for pair in (m.group("labels") or "").split(","):
            if "=" in pair:
                k, v = pair.split("=", 1)
                labels[k.strip()] = v.strip().strip('"')
        try:
            value = float(m.group("value"))
        except ValueError:
            continue
        out.setdefault(m.group("name"), []).append((labels, value))
    return out


def _prom_sum(metrics, name, label=None, values=None):
    """Total of `name`, optionally only the series whose `label` is in `values`."""
    total = 0.0
    for labels, value in metrics.get(name, []):
        if values is not None and labels.get(label) not in values:
            continue
        total += value
    return total


def fetch_aperture(cfg, run, now=None, state_path=None):
    """Tokens and requests per day, plus the cache-read share of input.

    Every counter Aperture exposes is monotonic and all-time — 237,201 requests and
    866M tokens since 2026-04-23 — so reporting them raw would put two more
    never-changing numbers on the dashboard, which is the very thing the rest of
    this change removes. What a gateway tile should answer is "how much am I using
    it", so the first two fields are RATES, derived by differencing against the
    previous reading.

    That needs one piece of durable state, and it deliberately does NOT live in
    stats.json: that file is the served payload, and a raw baseline counter in it
    would be a fourth field on a three-field tile — the `locations` mistake again.
    It goes in its own file next to it via nicos_scripts.state instead.

    The third field needs no state at all. cache_read over total input is the
    prompt-cache hit rate, currently ~95%, and it is the number that explains the
    bill: an uncached 866M-token month costs an order of magnitude more than a
    cached one.
    """
    now = now or time.time()
    state_path = state_path or os.path.join(cfg.state_dir, "aperture-counters.json")

    metrics = parse_prometheus(curl_text(cfg, run, cfg.aperture_metrics_url))
    tokens = _prom_sum(metrics, "aperture_generations_tokens_total",
                       label="type", values=_TOKEN_TYPES)
    requests = _prom_sum(metrics, "aperture_captured_requests_total")
    cache_read = _prom_sum(metrics, "aperture_generations_tokens_total",
                           label="type", values=("cache_read",))
    # llm_tokens_total{input} is input INCLUDING cache reads, which is exactly the
    # denominator wanted here: 817M/863M = 95%. Falling back to the summed total
    # keeps the field from dividing by zero on an instance that has served nothing.
    billed_input = _prom_sum(metrics, "aperture_llm_tokens_total",
                             label="type", values=("input",)) or tokens

    prev = state.load_json(state_path, {})
    elapsed = now - prev.get("at", 0)
    # A counter that went BACKWARDS means the instance was replaced or its durable
    # keyvalue counters were reset. There is no meaningful delta across that, so
    # treat it as a first reading rather than rendering a negative rate.
    reset = tokens < prev.get("tokens", 0) or requests < prev.get("requests", 0)

    if prev and not reset and elapsed >= APERTURE_MIN_ELAPSED:
        days = elapsed / 86400
        rates = {
            "tokens_per_day": (tokens - prev["tokens"]) / days,
            "requests_per_day": (requests - prev["requests"]) / days,
        }
        state.save_json(state_path, {"at": now, "tokens": tokens,
                                    "requests": requests, **rates})
    elif prev and not reset:
        # Too soon to re-measure: keep both the baseline and the last known rate.
        rates = {k: prev.get(k) for k in ("tokens_per_day", "requests_per_day")}
    else:
        # First reading ever, or after a reset: record the baseline and report no
        # rate. An em dash rather than 0 — see pct_delta, same reasoning. "0
        # tokens/day" would be a measurement, and this is the absence of one.
        rates = {"tokens_per_day": None, "requests_per_day": None}
        state.save_json(state_path, {"at": now, "tokens": tokens, "requests": requests})

    def rate(key, fmt):
        value = rates.get(key)
        return "—" if value is None else fmt(value)

    return {
        "tokens": rate("tokens_per_day", compact),
        "requests": rate("requests_per_day", compact),
        "cached": f"{cache_read / billed_input * 100:.0f}%" if billed_input else "—",
    }


def fetch_forgejo(cfg, run):
    """Repositories, overdue mirrors, and bytes on disk.

    `issues` and `pulls` used to be the second and third fields and both are
    structurally 0: of 167 repositories 68 are mirrors and the rest are personal
    pushes, so nothing here has ever had an issue tracker in use. Counting them
    was two thirds of a tile spent proving that.

    What this instance is FOR is mirroring, so the useful question is whether the
    mirrors are actually running — and the field earns itself immediately, because
    they are not: `next_update_unix` is in the past for all 68, the newest sync is
    2026-08-11, and nothing on the dashboard said so. Same shape as beszel's
    `alerts`: 0 when healthy, non-zero exactly when you want to know.
    """
    def count(sql):
        return int(pg_superuser(cfg, run, "forgejo", sql) or 0)

    return {
        "repositories": count("SELECT COUNT(*) FROM repository;"),
        # next_update_unix is when Forgejo intends to sync next, so "in the past"
        # means the scheduler has not got to it — which covers both a stalled
        # queue and a mirror whose interval has been missed. Compared in SQL
        # against the database's own clock rather than Python's, so the two cannot
        # disagree.
        "stale_mirrors": count("""
            SELECT COUNT(*) FROM mirror
             WHERE next_update_unix > 0
               AND next_update_unix < EXTRACT(EPOCH FROM now());
        """),
        # repository.size is the git directory in bytes, already maintained by
        # Forgejo — no du walk over /var/lib/forgejo needed.
        "size": count("SELECT COALESCE(SUM(size), 0) FROM repository;"),
    }


# Complete local days of an ha-linky statistic, newest first. 23 rather than 24
# because a DST day is 23 or 25 hours long; the point of the HAVING is to drop
# PARTIAL days, which is also what excludes today and the lagging tail (Enedis
# publishes about two days behind, so the newest rows are always incomplete).
#
# `state` is the per-hour increment for these — ha-linky writes both `state` and a
# cumulative `sum`, and summing `state` over the day matches the meter. That is NOT
# true of the Voltalis sensors, whose `state` is a running daily counter that resets
# at midnight; those are read live from /api/states below rather than from here.
_LINKY_DAYS = """
    SELECT date(s.start_ts, 'unixepoch', 'localtime') AS day, SUM(s.state) AS v
    FROM statistics s JOIN statistics_meta m ON m.id = s.metadata_id
    WHERE m.statistic_id LIKE 'linky:%' AND m.unit_of_measurement = '{unit}'
    GROUP BY day HAVING COUNT(*) >= 23
"""

# Last reported day, and the mean of the seven before it.
LINKY_DAY_SQL = f"""
WITH d AS ({_LINKY_DAYS.format(unit='Wh')} ORDER BY day DESC LIMIT 8)
SELECT COALESCE((SELECT v FROM d ORDER BY day DESC LIMIT 1), 0) || '|' ||
       COALESCE((SELECT AVG(v) FROM (SELECT v FROM d ORDER BY day DESC LIMIT 7 OFFSET 1)), 0);
"""

# Rolling 30 days of cost against the 30 before it: total, then both daily means.
# A rolling window rather than month-to-date because the meter's two-day lag makes
# the first days of a month report nothing at all, and "0 EUR" is a worse lie than
# a window that straddles the boundary.
LINKY_COST_SQL = f"""
WITH c AS ({_LINKY_DAYS.format(unit='€')})
SELECT COALESCE(SUM(CASE WHEN day > date('now','localtime','-30 day') THEN v END), 0) || '|' ||
       COALESCE(AVG(CASE WHEN day > date('now','localtime','-30 day') THEN v END), 0) || '|' ||
       COALESCE(AVG(CASE WHEN day > date('now','localtime','-60 day')
                          AND day <= date('now','localtime','-30 day') THEN v END), 0)
FROM c;
"""


def _floats(scalar, n):
    """Split a pipe-joined SQL row into n floats, tolerating an empty result."""
    parts = (scalar or "").split("|")
    return [float(parts[i] or 0) if i < len(parts) else 0.0 for i in range(n)]


def fetch_homeassistant(cfg, run):
    """Electricity, each figure against something — not entity counts.

    The tile used to report people_home / lights_on / switches_on, and two of the
    three could not move. There is exactly one `person.` entity, so "Home" was a
    boolean; and this install has no `light.` entities AT ALL, so "Lights" was a
    structural 0 dressed up as a measurement. Nothing about that told you anything
    you would act on.

    What this Home Assistant actually is, is an electricity meter: ha-linky
    backfills Enedis consumption and cost as long-term statistics, and Voltalis
    reports per-room heater use. So the tile reports energy, and every figure
    carries a comparison — a kWh with nothing beside it is not information.

    Two sources, because neither alone covers it. Long-term statistics live only in
    the recorder database (the REST API has the present, and statistics are reachable
    only over the WEBSOCKET API), while the Voltalis daily counters are live states
    whose statistics rows cannot be summed — see _LINKY_DAYS. HA is always-on, so
    reading either wakes nothing.
    """
    day_wh, day_mean = _floats(sqlite_scalar(cfg, run, cfg.hass_db, LINKY_DAY_SQL), 2)
    cost, cost_mean, prev_mean = _floats(
        sqlite_scalar(cfg, run, cfg.hass_db, LINKY_COST_SQL), 3)

    token = env_var(cfg, "HA_TOKEN")
    states = curl_json(cfg, run, f"{cfg.hass_url}/api/states",
                       "-H", f"Authorization: Bearer {token}",
                       "-H", "Content-Type: application/json")

    def entities(suffix):
        return [e for e in states if e.get("entity_id", "").endswith(suffix)]

    def numeric(state):
        # Voltalis drops to "unknown"/"unavailable" between polls and for a while
        # after an HA restart; that is absence, not zero consumption, but a tile
        # cannot show absence, and treating it as 0 only ever understates.
        try:
            return float(state)
        except (TypeError, ValueError):
            return 0.0

    heater_wh = sum(numeric(e.get("state"))
                    for e in entities("_daily_consumption"))
    rooms_on = sum(1 for e in entities("_device_switch") if e.get("state") == "on")

    return {
        # "Yesterday" is the last day the meter REPORTED, roughly two days back —
        # there is no honest way to show today, and labelling the lag would cost
        # more room than the number is worth.
        "day": f"{watt_hours(day_wh)} ({pct_delta(day_wh, day_mean)})",
        "cost": f"€{cost:,.2f} ({pct_delta(cost_mean, prev_mean)})",
        "heating": f"{watt_hours(heater_wh)} ({rooms_on} on)",
    }


# Single source for "which fetcher owns which stats key", used by both the daily
# refresh and the startup backfill. Keeping it a dict rather than a call list means
# a newly added widget cannot be wired into one and forgotten in the other.
FETCHERS = {
    "sure": fetch_sure,
    "wealthfolio": fetch_wealthfolio,
    "immich": fetch_immich,
    "nextcloud": fetch_nextcloud,
    "calino": fetch_calino,
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
    "freereps": fetch_freereps,
    "aperture": fetch_aperture,
}

# NOTE: every published key must have a fetcher and vice versa. The two used to be
# separate literals, so a new widget could be added to one and forgotten in the
# other — its tile would then read empty forever. Checked by
# test_homepage_stats.py rather than an import-time assert.


def run_fetcher(cfg, run, stats, key, log=None):
    """Run one fetcher, recording either its result or its error.

    This is the single copy of what used to be nineteen identical
    `try/except → stats[key]["error"] = str(e)` blocks.

    The failure is logged as well as recorded because Stats.error() MERGES into the
    existing entry: a broken fetcher keeps publishing its last good numbers, and the
    tile renders them with nothing to say they are frozen. That is how the AFFiNE
    tile served two-day-old counts after the 0.27.3 upgrade killed its token — the
    payload said `error` and nothing anywhere said it out loud. `journalctl -u
    homepage-stats | grep 'fetch failed'` is now the answer to "is a tile lying?".
    """
    try:
        stats.set(key, FETCHERS[key](cfg, run))
        return True
    except Exception as e:  # noqa: BLE001 — one broken service must not stop the rest
        stats.error(key, str(e))
        if log:
            log(f"{key} fetch failed: {e}")
        return False


# ── cache ────────────────────────────────────────────────────────────────────

def load_cache(cfg, stats, log=None):
    log = log or (lambda m: print(m, file=sys.stderr))
    try:
        with open(cfg.state_file) as f:
            payload = json.load(f)
        if payload.get("_schema") != STATS_SCHEMA:
            # Leave every key empty so backfill_missing does a full fetch, dated now.
            log(f"cache schema {payload.get('_schema')} != {STATS_SCHEMA}, refetching all")
            return 0
        stats.replace_all(payload)
        return payload.get("_fetched_at", 0)
    except FileNotFoundError:
        return 0
    except Exception as e:  # noqa: BLE001
        log(f"cache load failed: {e}")
        return 0


def save_cache(cfg, stats, ts, log=None):
    log = log or (lambda m: print(m, file=sys.stderr))
    try:
        os.makedirs(cfg.state_dir, exist_ok=True)
        payload = stats.snapshot()
        payload["_fetched_at"] = ts
        payload["_schema"] = STATS_SCHEMA
        tmp = cfg.state_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, cfg.state_file)
    except Exception as e:  # noqa: BLE001
        log(f"cache save failed: {e}")


def backfill_missing(cfg, run, stats, fetched_at, log=None):
    """Populate keys the cache has no entry for. -> the timestamp to schedule from.

    Without this, adding a widget means its tile reads empty for up to
    refresh_interval (a full day): load_cache() seeds every key from the cached
    payload, and a key absent from that payload stays {} until the next daily tick,
    which is scheduled from the EXISTING cache timestamp. Only missing keys are
    fetched, so this costs nothing for services already cached and will not wake the
    socket-activated ones on every restart.

    The original timestamp is preserved when there was one, so backfilling a single
    new widget does not push the whole daily refresh back by a day. On a cold cache
    everything is missing, so this IS the first full fetch and dates from now —
    which also stops refresh() from immediately repeating it.
    """
    log = log or (lambda m: print(m, file=sys.stderr))
    missing = stats.missing()
    if not missing:
        return fetched_at
    log(f"backfilling: {', '.join(missing)}")
    for key in missing:
        run_fetcher(cfg, run, stats, key, log=log)
    ts = fetched_at or time.time()
    save_cache(cfg, stats, ts)
    return ts


def refresh(cfg, run, stats, initial_fetched_at, sleep=time.sleep, once=False, log=None):
    # Runs in the refresh thread, not at startup, so the HTTP listener comes up
    # immediately serving cached data rather than blocking on a cold-cache fetch.
    log = log or (lambda m: print(m, file=sys.stderr))
    last_fetched = backfill_missing(cfg, run, stats, initial_fetched_at, log=log)
    while True:
        # A key that is STILL empty after the backfill gets another go in a
        # minute rather than tomorrow. The case that keeps happening: a rebuild
        # restarts homepage-stats and the service it reads from together, the
        # fetch loses the race, and the tile then shows an error for 24h. One
        # retry is enough — the loser of that race is up seconds later.
        if stats.missing():
            sleep(RETRY_INTERVAL)
            backfill_missing(cfg, run, stats, last_fetched, log=log)
        next_due = last_fetched + cfg.refresh_interval
        wait = max(0, next_due - time.time())
        if wait:
            sleep(wait)
        try:
            for key in FETCHERS:
                run_fetcher(cfg, run, stats, key, log=log)
            last_fetched = time.time()
            save_cache(cfg, stats, last_fetched)
        except Exception as e:  # noqa: BLE001
            log(f"refresh error: {e}")
            # Retry in 1 hour on failure rather than waiting another full day.
            last_fetched = time.time() - cfg.refresh_interval + 3600
        if once:
            return last_fetched


def make_handler(stats):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            # One branch per service used to be spelled out here, which meant adding
            # a widget touched three places. The stats object already knows every
            # key, so route straight off it; anything else (including /) serves the
            # whole payload.
            key = self.path.strip("/")
            data = stats.get(key) if key in stats else stats.snapshot()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())

        def log_message(self, *a):
            pass

    return Handler


def main(env=None, run=None, server_class=http.server.HTTPServer):
    cfg = Config.from_env(env)
    run = run or shell_runner
    stats = Stats()
    # Load cache synchronously before serving so a restart never returns
    # an empty payload while waiting on the daily refresh.
    initial_fetched_at = load_cache(cfg, stats)
    threading.Thread(target=refresh, args=(cfg, run, stats, initial_fetched_at),
                     daemon=True).start()
    server_class(("127.0.0.1", cfg.port), make_handler(stats)).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
