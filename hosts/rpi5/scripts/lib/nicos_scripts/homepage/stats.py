#!/usr/bin/env python3
"""Tiny stats aggregation API for homepage-dashboard widgets.

Aggregates data from multiple service APIs into simple JSON endpoints,
refreshed once per day. Serves on 127.0.0.1:8087.

Endpoints (one per homepage tile, three stats each):
  /          — all stats
  /sure      — Sure (cash + spendable, spend + budget left, food + food left) — direct Postgres
  /wealthfolio — Wealthfolio (net worth + investments, invested + gain, 30-day return)
  /immich    — Immich (photos, videos, storage)
  /nextcloud — Nextcloud (active users, files, shares) — serverinfo OCS API
  /affine    — AFFiNE (workspaces, docs, storage) — direct Postgres, summed across workspaces
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
substitute, which is what makes 19 fetchers checkable without the services they
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
from dataclasses import dataclass

from ..secrets import env_int, env_str

DEFAULT_STATE_DIR = "/var/lib/homepage-stats"
REFRESH_INTERVAL = 86400  # seconds — see module docstring

# Bump whenever a fetcher changes WHICH fields it reports (renaming wakapi's
# heartbeats→today, say), so the cache from the previous shape is discarded.
# backfill_missing only re-fetches keys that are entirely absent, so without this a
# key whose fields were renamed would keep serving the old shape — blanking its tile
# — until the next daily refresh, up to 24h after the rebuild that changed it.
STATS_SCHEMA = 10


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
    sure_url: str = "http://127.0.0.1:13334/sure"
    # The app's own bind, not the read-only :3700 vhost — see fetch_wealthfolio.
    wealthfolio_url: str = "http://127.0.0.1:13345"
    # Cost basis is not exposed by any endpoint, only by this table. Read-only,
    # and this service runs as root so the 0700 state dir is reachable.
    wealthfolio_db: str = "/var/lib/wealthfolio/wealthfolio.db"
    immich_url: str = "http://127.0.0.1:2283"
    hass_url: str = "http://127.0.0.1:8123"

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
            nextcloud_info_url=s("NEXTCLOUD_INFO_URL", cls.nextcloud_info_url),
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
        "nextcloud", "affine", "beszel",
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
        with self._lock:
            return [k for k, v in self._data.items() if not v]

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
          SELECT id FROM categories WHERE name = '1 - Food'
          UNION SELECT id FROM categories
                WHERE parent_id IN (SELECT id FROM categories WHERE name = '1 - Food')
        )
        SELECT COALESCE((SELECT round(bc.budgeted_spending::numeric, 2)
                         FROM budget_categories bc
                         JOIN budgets b ON b.id = bc.budget_id
                         JOIN categories c ON c.id = bc.category_id
                         WHERE c.name = '1 - Food'
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
    data = curl_json(cfg, run, cfg.nextcloud_info_url,
                     "-H", f"NC-Token: {env_var(cfg, 'NEXTCLOUD_PASSWORD')}",
                     "-H", "OCS-APIRequest: true")["ocs"]["data"]
    return {
        "users": data["activeUsers"]["last24hours"],
        "files": data["nextcloud"]["storage"]["num_files"],
        "shares": data["nextcloud"]["shares"]["num_shares"],
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
        "workspaces": count("SELECT COUNT(*) FROM workspaces;"),
        # workspace_pages is AFFiNE's registry of actual docs. `snapshots` holds a
        # few more rows — one Yjs doc per workspace for the doc list itself — which
        # are not docs anyone would count on a dashboard.
        "docs": count("SELECT COUNT(*) FROM workspace_pages;"),
        # deleted_at IS NULL reproduced GraphQL's blobsSize to the byte
        # (558516275); summing every row instead over-reports by the tombstones.
        "storage": count(
            "SELECT COALESCE(SUM(size), 0) FROM blobs WHERE deleted_at IS NULL;"),
    }


def fetch_beszel(cfg, run):
    # Read-only direct SQLite query against Beszel's PocketBase DB — same trick as
    # fetch_karakeep. `alerts.triggered` is the interesting one: it's what actually
    # fired, not how many alert rules exist.
    return {
        "systems": sqlite_count(cfg, run, cfg.beszel_db, "SELECT COUNT(*) FROM systems;"),
        "up": sqlite_count(cfg, run, cfg.beszel_db,
                           "SELECT COUNT(*) FROM systems WHERE status = 'up';"),
        "alerts": sqlite_count(cfg, run, cfg.beszel_db,
                               "SELECT COUNT(*) FROM alerts WHERE triggered = 1;"),
    }


def fetch_karakeep(cfg, run):
    # Read-only direct SQLite query — no API key, never wakes karakeep.
    return {
        "bookmarks": sqlite_count(cfg, run, cfg.karakeep_db, "SELECT COUNT(*) FROM bookmarks;"),
        "favorites": sqlite_count(cfg, run, cfg.karakeep_db,
                                  "SELECT COUNT(*) FROM bookmarks WHERE favourited = 1;"),
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
    db = cfg.showmycards_db
    return {
        "cards": sqlite_count(cfg, run, db, "SELECT COALESCE(SUM(quantity),0) FROM inventories;"),
        "decks": sqlite_count(cfg, run, db, "SELECT COUNT(*) FROM lists;"),
        "locations": sqlite_count(cfg, run, db, "SELECT COUNT(*) FROM storage_locations;"),
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

    return {
        "resumes": int(q("SELECT COUNT(*) FROM resume;") or 0),
        "users": int(q('SELECT COUNT(*) FROM "user";') or 0),
        "views": int(q("SELECT COALESCE(SUM(views), 0) FROM resume_statistics;") or 0),
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
    db = cfg.vaultwarden_db
    return {
        "items": sqlite_count(cfg, run, db,
                              "SELECT COUNT(*) FROM ciphers WHERE deleted_at IS NULL;"),
        "users": sqlite_count(cfg, run, db, "SELECT COUNT(*) FROM users;"),
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
    return {
        "points": int(pg_superuser(cfg, run, "dawarich", "SELECT COUNT(*) FROM points;") or 0),
        "trips": int(pg_superuser(cfg, run, "dawarich", "SELECT COUNT(*) FROM trips;") or 0),
        "visits": int(pg_superuser(cfg, run, "dawarich", "SELECT COUNT(*) FROM visits;") or 0),
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


def fetch_forgejo(cfg, run):
    return {
        "repositories": int(pg_superuser(cfg, run, "forgejo",
                                         "SELECT COUNT(*) FROM repository;") or 0),
        "issues": int(pg_superuser(
            cfg, run, "forgejo",
            "SELECT COUNT(*) FROM issue WHERE is_pull=false AND is_closed=false;") or 0),
        "pulls": int(pg_superuser(
            cfg, run, "forgejo",
            "SELECT COUNT(*) FROM issue WHERE is_pull=true AND is_closed=false;") or 0),
    }


def fetch_homeassistant(cfg, run):
    # HA is always-on (not socket-activated), so polling it doesn't wake anything.
    # It's routed through this daily-cached aggregator only for consistency with
    # the other tiles — note the counts can be up to refresh_interval stale.
    token = env_var(cfg, "HA_TOKEN")
    states = curl_json(cfg, run, f"{cfg.hass_url}/api/states",
                       "-H", f"Authorization: Bearer {token}",
                       "-H", "Content-Type: application/json")

    def count(prefix, st):
        return sum(1 for e in states
                   if e.get("entity_id", "").startswith(prefix) and e.get("state") == st)

    return {
        "people_home": count("person.", "home"),
        "lights_on": count("light.", "on"),
        "switches_on": count("switch.", "on"),
    }


# Single source for "which fetcher owns which stats key", used by both the daily
# refresh and the startup backfill. Keeping it a dict rather than a call list means
# a newly added widget cannot be wired into one and forgotten in the other.
FETCHERS = {
    "sure": fetch_sure,
    "wealthfolio": fetch_wealthfolio,
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
