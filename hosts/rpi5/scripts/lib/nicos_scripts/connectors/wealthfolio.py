#!/usr/bin/env python3
"""Mirror Sure into Wealthfolio. One direction only.

Sure is the single writer. Wealthfolio is a read-only view whose whole content
is derived from this script, so nothing there needs to be edited by hand and
nothing here reads Wealthfolio's own state as truth.

WHY SNAPSHOTS AND NOT ACTIVITIES. Wealthfolio's obvious import path is
`POST /activities` — buys and sells, from which it derives holdings. Sure does
not have that data: its investment accounts are balance-tracked (10 accounts,
1200-odd holdings rows, but only 8 rows in `trades`), so a transaction history
would have to be invented. The first attempt did exactly that — one synthesised
BUY per position at the price Sure first recorded, plus a DEPOSIT to stop cash
going negative — and it works, but every number it produces about *performance*
is fiction, because the entry price and date are made up.

Wealthfolio has a second mode that matches Sure exactly: `TrackingMode.HOLDINGS`,
"holdings are manually entered or imported directly", whose write path is
`POST /api/v1/snapshots/import`. A snapshot is a full declarative statement of
the positions held in an account on a date — the same shape as a row in Sure's
`holdings` table. Feeding those in:

  * removes the invented trades entirely, and with them the cost-basis problem
    (Sure only knows cost basis for a handful of positions);
  * gets performance right anyway. Wealthfolio infers external flows by
    re-pricing the previous snapshot's QUANTITIES at current quotes, so a
    position going 269 -> 369 shares is booked as a contribution rather than a
    gain. Cost basis never enters the return calculation;
  * fills the gaps. Two keyframes a year apart produced 501 daily valuation
    rows, each re-priced from Yahoo. Sparse input, dense history.

IDEMPOTENCY IS STRUCTURAL, NOT DEFENDED. `AccountStateSnapshot::stable_id`
derives a UUIDv5 from "wealthfolio:snapshot:{account_id}:{date}", and the
repository does `replace_into`. Same account + same date is the same row, so a
re-run overwrites rather than duplicates and there is nothing here to
de-duplicate. Every position change falls out of that for free: a closed
position is one that is absent from the next snapshot, a new one is present in
it, a re-mapped symbol is simply the new truth. There is no diffing code
because there is nothing to diff.

SYMBOLS. Sure carries CoinStats-style crypto tickers (`CRYPTO:BTC`) and Yahoo —
Wealthfolio's provider — wants pairs (`BTC-USD`). That is a RULE, not a table:
`CRYPTO:X -> X-USD` resolves for every crypto in the data, including ETHX.
SYMBOL_OVERRIDES exists for the cases the rule gets wrong, and is empty until
one shows up. Everything else passes through untouched — the Paris/Frankfurt
listings and the three Morningstar `0P...F` employee-savings funds all resolve
on Yahoo as-is.

ALTERNATIVE ASSETS. Sure's Property and Loan have no account type in
Wealthfolio (it has only SECURITIES/CASH/CREDIT_CARD/CRYPTOCURRENCY), but they
do have an asset kind. They go in via `/alternative-assets`, and the loan is
LINKED to the property, so net worth shows equity instead of two unrelated
numbers.

Env contract (all set by hosts/rpi5/wealthfolio-sync.nix):
  WF_URL          Wealthfolio API base. Defaults to the loopback bind, which
                  deliberately bypasses the read-only nginx allowlist on :3700.
  WF_PASSWORD     login password (agenix)
  SURE_DB         Sure's PostgreSQL database name
  BACKFILL_FROM   "" (default) syncs the latest date only; "2025-04-01" walks
                  history from there. Set once for the initial load.
  STATE_DIR       systemd StateDirectory
  DRY_RUN         "1" (default) builds the payloads and posts nothing
"""

import dataclasses
import datetime
import json
import sys
import urllib.error
import urllib.request

from ..logs import logger
from ..secrets import env_str

TAG = "sure-to-wealthfolio"

DEFAULT_WF_URL = "http://127.0.0.1:13345"
DEFAULT_SURE_DB = "sure_production"
DEFAULT_STATE_DIR = "/var/lib/wealthfolio-sync"
DEFAULT_RUNUSER = "runuser"
DEFAULT_PSQL = "psql"

# Sure's accountable_type -> Wealthfolio account type. Wealthfolio has exactly
# four (accounts_constants.rs), so Property and Loan are NOT here: they are not
# accounts at all on that side, they are alternative assets. See sync_alternatives.
ACCOUNT_TYPES = {
    "Investment": "SECURITIES",
    "Crypto": "CRYPTOCURRENCY",
    "Depository": "CASH",
    "CreditCard": "CREDIT_CARD",
}

# Only for symbols the CRYPTO: rule below gets wrong. Empty on purpose — every
# crypto in the data maps correctly by rule, and a table that restates the rule
# is a table that drifts from it.
SYMBOL_OVERRIDES = {}

# Wealthfolio's own default_group_for_account_type, restated so the sidebar
# groups match what the app would have chosen by hand.
GROUPS = {
    "SECURITIES": "Investments",
    "CRYPTOCURRENCY": "Crypto",
    "CASH": "Cash",
    "CREDIT_CARD": "Credit Cards",
}


def map_symbol(ticker):
    """Sure's ticker -> the symbol Yahoo quotes it under."""
    if ticker in SYMBOL_OVERRIDES:
        return SYMBOL_OVERRIDES[ticker]
    if ticker.startswith("CRYPTO:"):
        return f"{ticker[len('CRYPTO:'):]}-USD"
    return ticker


def is_crypto_pair(symbol):
    return symbol.endswith("-USD")


@dataclasses.dataclass(frozen=True)
class Config:
    wf_url: str = DEFAULT_WF_URL
    wf_password: str = ""
    sure_db: str = DEFAULT_SURE_DB
    backfill_from: str = ""
    state_dir: str = DEFAULT_STATE_DIR
    runuser: str = DEFAULT_RUNUSER
    psql: str = DEFAULT_PSQL
    # Defaults to the SAFE value: a Config built with no env cannot write.
    dry_run: bool = True

    @classmethod
    def from_env(cls, env=None):
        return cls(
            wf_url=env_str("WF_URL", DEFAULT_WF_URL, env).rstrip("/"),
            wf_password=env_str("WF_PASSWORD", "", env).strip(),
            sure_db=env_str("SURE_DB", DEFAULT_SURE_DB, env),
            backfill_from=env_str("BACKFILL_FROM", "", env).strip(),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
            runuser=env_str("RUNUSER_BIN", DEFAULT_RUNUSER, env),
            psql=env_str("PSQL_BIN", DEFAULT_PSQL, env),
            dry_run=env_str("DRY_RUN", "1", env) != "0",
        )


# ── Sure (read side) ─────────────────────────────────────────────────────────

def pg(cfg, run, sql):
    """Read-only SELECT as the postgres superuser over the local socket.

    Peer auth, same as homepage/stats.py: the sync user cannot read
    sure-pg-password (it is owned by postgres), and does not need to.
    """
    out = run([cfg.runuser, "-u", "postgres", "--", cfg.psql,
               "-d", cfg.sure_db, "-tAF\x1f", "-c", sql])
    rows = []
    for line in out.splitlines():
        if line.strip():
            rows.append(line.split("\x1f"))
    return rows


def sure_accounts(cfg, run):
    """Sure's non-draft accounts, as (id, name, accountable_type, currency)."""
    rows = pg(cfg, run, """
        SELECT id, name, accountable_type, currency
        FROM accounts
        WHERE status <> 'draft'
        ORDER BY name
    """)
    return [
        {"id": r[0], "name": r[1].strip(), "kind": r[2], "currency": r[3]}
        for r in rows
    ]


def sure_positions(cfg, run, since):
    """Every (account, date) position set, cost basis forward-filled.

    `since` bounds the walk; "" means the latest date per account only. The
    forward-fill matters because Sure populates cost_basis sporadically — the
    LAST row of a position often has none while its history does — and a NULL
    would otherwise erase a basis Wealthfolio already knows.
    """
    bound = f"AND h.date >= DATE '{since}'" if since else ""
    latest_only = "" if since else """
        AND h.date = (SELECT max(date) FROM holdings h2
                      WHERE h2.account_id = h.account_id AND h2.qty > 0)
    """
    rows = pg(cfg, run, f"""
        SELECT a.name, h.date, s.ticker, h.qty, h.currency,
               COALESCE(
                 h.cost_basis,
                 (SELECT h3.cost_basis FROM holdings h3
                  WHERE h3.account_id = h.account_id
                    AND h3.security_id = h.security_id
                    AND h3.date <= h.date
                    AND h3.cost_basis IS NOT NULL
                  ORDER BY h3.date DESC LIMIT 1)
               ),
               s.exchange_operating_mic
        FROM holdings h
        JOIN accounts a ON a.id = h.account_id
        JOIN securities s ON s.id = h.security_id
        WHERE h.qty > 0 {bound} {latest_only}
        ORDER BY a.name, h.date, s.ticker
    """)
    out = {}
    for name, date, ticker, qty, ccy, basis, mic in rows:
        symbol = map_symbol(ticker)
        pos = {"symbol": symbol, "quantity": qty,
               "currency": "USD" if is_crypto_pair(symbol) else ccy}
        # Crypto has no cost basis in Sure at all. Sending 0 would render as a
        # 100%-gain position; omitting it leaves the column honestly blank.
        if basis and not is_crypto_pair(symbol):
            pos["avgCost"] = basis
        # `mic` is read but deliberately NOT sent. Sure's exchange_operating_mic
        # is not always a MIC: the German listings carry the string "GER"
        # (SXRT.DE, MAGR.DE), and passing that through pins the asset to a
        # non-existent exchange, so Yahoo never quotes it and the position
        # values at zero — silently, since the quantity is still right.
        # Wealthfolio resolves the real MIC from the symbol suffix on its own
        # (.DE -> XETR, verified against /snapshots/import/check), which is
        # strictly better than anything Sure can tell us.
        out.setdefault((name.strip(), date), []).append(pos)
    return out


def sure_cash(cfg, run, since):
    """Latest cash balance per depository/credit-card account, per date."""
    bound = f"AND b.date >= DATE '{since}'" if since else """
        AND b.date = (SELECT max(date) FROM balances b2 WHERE b2.account_id = b.account_id)
    """
    rows = pg(cfg, run, f"""
        SELECT a.name, b.date, b.balance, a.currency
        FROM balances b
        JOIN accounts a ON a.id = b.account_id
        WHERE a.accountable_type IN ('Depository', 'CreditCard')
          AND a.status <> 'draft' {bound}
        ORDER BY a.name, b.date
    """)
    return {(n.strip(), d): {c: bal} for n, d, bal, c in rows}


def sure_trades(cfg, run):
    """Sure's real buys — actual dates, actual prices, no inference.

    There are only a handful (Sure's investment accounts are balance-tracked),
    but they are REAL, which the snapshot path's prices are not: those are
    whatever the position was worth on the day Sure started watching it. An
    account whose every position has a trade can therefore be tracked by
    TRANSACTIONS instead of HOLDINGS, and Wealthfolio will compute TWR and IRR
    for it — both of which it refuses in holdings mode, because it has no
    observed cash flows to compute them from.
    """
    rows = pg(cfg, run, """
        SELECT a.name, s.ticker, e.date, t.qty, t.price, t.currency
        FROM trades t
        JOIN entries e ON e.entryable_id = t.id AND e.entryable_type = 'Trade'
        JOIN accounts a ON a.id = e.account_id
        JOIN securities s ON s.id = t.security_id
        WHERE a.status <> 'draft' AND t.qty > 0
        ORDER BY e.date
    """)
    out = {}
    for name, ticker, date, qty, price, ccy in rows:
        symbol = map_symbol(ticker)
        out.setdefault(name.strip(), []).append({
            "symbol": symbol, "date": date, "quantity": qty, "price": price,
            "currency": "USD" if is_crypto_pair(symbol) else ccy,
        })
    return out


def sure_goals(cfg, run):
    """Active savings goals. Sure's `state` is the lifecycle; archived ones stay put."""
    rows = pg(cfg, run, """
        SELECT name, target_amount, currency, COALESCE(target_date::text, '')
        FROM goals WHERE state = 'active' ORDER BY created_at
    """)
    return [
        {"title": n.strip(), "target": float(t), "currency": c, "target_date": d or None}
        for n, t, c, d in rows
    ]


def sure_alternatives(cfg, run):
    """Property and Loan accounts — Wealthfolio alternative assets, not accounts."""
    rows = pg(cfg, run, """
        SELECT name, accountable_type, currency, balance
        FROM accounts
        WHERE accountable_type IN ('Property', 'Loan') AND status <> 'draft'
        ORDER BY accountable_type
    """)
    kinds = {"Property": "property", "Loan": "liability"}
    return [
        {"name": n.strip(), "kind": kinds[t], "currency": c, "value": bal}
        for n, t, c, bal in rows
    ]


# ── Wealthfolio (write side) ─────────────────────────────────────────────────

class Wealthfolio:
    """The REST API, carrying the session cookie by hand.

    A CookieProcessor is the obvious way to do this and it silently does not
    work. The service runs with WF_COOKIE_SECURE=true — it must, because
    Tailscale Serve terminates TLS in front of it — so `wf_session` comes back
    flagged Secure. We talk to the loopback bind over plain HTTP, and every
    conforming cookie jar (including http.cookiejar) REFUSES to store a Secure
    cookie received over an insecure scheme. The jar stays empty, the next call
    401s, and nothing anywhere says why.

    Reading Set-Cookie off the login response and echoing it back sidesteps the
    policy rather than weakening it: the flag still protects the browser, and
    this hop never leaves the machine.
    """

    def __init__(self, base, opener=None):
        self.base = base
        self._open = opener or urllib.request.urlopen
        self._cookie = None

    def call(self, method, path, body=None, timeout=300):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Accept": "application/json"}
        if data:
            headers["Content-Type"] = "application/json"
        if self._cookie:
            headers["Cookie"] = self._cookie
        req = urllib.request.Request(
            f"{self.base}/api/v1{path}", data=data, headers=headers, method=method
        )
        with self._open(req, timeout=timeout) as resp:
            raw = resp.read()
            self._capture_session(resp)
        return json.loads(raw) if raw else None

    def _capture_session(self, resp):
        """Keep wf_session from any response — it is re-issued past half the TTL."""
        headers = getattr(resp, "headers", None)
        if headers is None:
            return
        for raw in headers.get_all("Set-Cookie") or []:
            name_value = raw.split(";", 1)[0].strip()
            if name_value.startswith("wf_session="):
                self._cookie = name_value

    def login(self, password):
        return self.call("POST", "/auth/login", {"password": password})

    def accounts(self):
        return self.call("GET", "/accounts") or []


def ensure_account(wf, log, name, account_type, currency, group, dry_run,
                   tracking_mode="HOLDINGS"):
    """Create the account if absent; return its id (None when dry and absent)."""
    for a in wf.accounts():
        if a["name"] == name:
            return a["id"]
    if dry_run:
        log(f"DRY would create account {name} ({account_type}/{currency}, {tracking_mode})")
        return None
    created = wf.call("POST", "/accounts", {
        "name": name, "accountType": account_type, "group": group,
        "currency": currency, "isDefault": False, "isActive": True,
        # HOLDINGS, not TRANSACTIONS: this account's positions are stated by
        # the sync, never derived from a trade history it does not have.
        #
        # Credit cards are the one type the server refuses it for ("Credit card
        # accounts cannot use HOLDINGS tracking mode", accounts_model.rs:305) —
        # they hold a balance, never positions. NOT_SET leaves the balance to
        # come from the snapshot's cashBalances like any other cash account.
        "trackingMode": "NOT_SET" if account_type == "CREDIT_CARD" else tracking_mode,
    })
    log(f"created account {name} -> {created['id'][:8]}")
    return created["id"]


def import_snapshots(wf, log, account_id, snapshots, dry_run):
    """check -> import for one account. Aborts the account on an unresolved symbol.

    A half-written account is worse than an unwritten one: the missing position
    would read as a real sale on the dates it is absent, so an unknown symbol
    stops this account rather than importing around it.
    """
    payload = {"accountId": account_id, "snapshots": snapshots}
    checked = wf.call("POST", "/snapshots/import/check", payload)
    missing = [s["symbol"] for s in (checked or {}).get("symbols", []) if not s.get("found")]
    if missing:
        log(f"ERROR unresolved symbols {sorted(set(missing))} — account skipped")
        return 0

    # Carry the resolved assetIds back so the import does not re-resolve them.
    resolved = {s["symbol"]: s.get("assetId")
                for s in (checked or {}).get("symbols", []) if s.get("assetId")}
    for snap in snapshots:
        for pos in snap["positions"]:
            if pos["symbol"] in resolved:
                pos["assetId"] = resolved[pos["symbol"]]

    if dry_run:
        log(f"DRY would import {len(snapshots)} snapshot(s)")
        return 0
    result = wf.call("POST", "/snapshots/import", payload)
    if result.get("snapshotsFailed"):
        log(f"WARN {result['snapshotsFailed']} snapshot(s) failed: {result.get('errors')}")
    return result.get("snapshotsImported", 0)


def sync_alternatives(wf, log, alternatives, today, dry_run):
    """Property + Loan, with the loan linked to the property.

    Linking is what makes net worth read as equity rather than as an asset and
    an unrelated debt sitting side by side.

    `today` is passed in rather than read from the clock: the server parses it
    strictly as %Y-%m-%d, and a caller-supplied date is what makes this testable.
    """
    existing = {a["name"]: a for a in (wf.call("GET", "/alternative-holdings") or [])}
    ids = {}
    for alt in alternatives:
        if alt["name"] in existing:
            ids[alt["kind"]] = existing[alt["name"]]["id"]
            if not dry_run:
                wf.call("PUT", f"/alternative-assets/{ids[alt['kind']]}/valuation",
                        {"value": alt["value"], "date": today})
            continue
        if dry_run:
            log(f"DRY would create {alt['kind']} {alt['name']} = {alt['value']} {alt['currency']}")
            continue
        created = wf.call("POST", "/alternative-assets", {
            "kind": alt["kind"], "name": alt["name"], "currency": alt["currency"],
            "currentValue": alt["value"], "valueDate": today,
        })
        ids[alt["kind"]] = created["assetId"]
        log(f"created {alt['kind']} {alt['name']}")

    if not dry_run and "liability" in ids and "property" in ids:
        wf.call("POST", f"/alternative-assets/{ids['liability']}/link-liability",
                {"targetAssetId": ids["property"]})
        log("linked liability -> property")


def build_snapshots(positions, cash):
    """Merge the two reads into one snapshot list per account.

    A snapshot is the WHOLE state of an account on a date, so positions and
    cash for the same (account, date) have to end up in the SAME entry — one
    keyed union, not two passes. Two passes is what the first version did, with
    an `if name not in by_account` guard that let exactly one cash date through
    per account and silently dropped the rest: every cash account ended up
    showing whichever balance happened to sort first, which for a savings
    account read as a five-figure negative.
    """
    dates = {}
    for (name, date), pos in positions.items():
        dates.setdefault((name, date), {})["positions"] = pos
    for (name, date), balances in cash.items():
        dates.setdefault((name, date), {})["cashBalances"] = balances

    by_account = {}
    for (name, date), parts in dates.items():
        by_account.setdefault(name, []).append({
            "date": date,
            "positions": parts.get("positions", []),
            "cashBalances": parts.get("cashBalances", {}),
        })
    for snapshots in by_account.values():
        snapshots.sort(key=lambda s: s["date"])
    return by_account


def sync_goals(wf, log, goals, dry_run):
    """Mirror Sure's goals. Matched on title, because neither side has a shared id."""
    existing = {g["title"]: g for g in (wf.call("GET", "/goals") or [])}
    for goal in goals:
        body = {
            "goalType": "SAVINGS", "title": goal["title"],
            "targetAmount": goal["target"], "currency": goal["currency"],
            "targetDate": goal["target_date"],
            "description": "Mirrored from Sure",
        }
        if goal["title"] in existing:
            if dry_run:
                continue
            wf.call("PUT", "/goals", {**existing[goal["title"]], **body})
            continue
        if dry_run:
            log(f"DRY would create goal {goal['title']} ({goal['target']:,.0f} {goal['currency']})")
            continue
        wf.call("POST", "/goals", body)
        log(f"created goal {goal['title']}")


def import_trades(wf, log, account_id, trades, dry_run):
    """Real buys, at their real dates and prices.

    A DEPOSIT precedes them covering the total cost: in TRANSACTIONS mode a BUY
    with no cash behind it drives the account's cash negative, and Sure does not
    model the transfer that funded the purchase. Dated the day before the first
    buy so it never lands after the money is spent.
    """
    if dry_run:
        log(f"DRY would import {len(trades)} trade(s)")
        return 0

    first = min(t["date"] for t in trades)
    funding = sum(float(t["quantity"]) * float(t["price"]) for t in trades)
    wf.call("POST", "/activities", {
        "accountId": account_id, "activityType": "DEPOSIT",
        "activityDate": f"{first}T00:00:00Z", "amount": round(funding, 2),
        "currency": trades[0]["currency"], "isDraft": False,
        "comment": "Opening balance imported from Sure",
    })
    n = 0
    for t in trades:
        wf.call("POST", "/activities", {
            "accountId": account_id,
            "asset": {
                "symbol": t["symbol"],
                "kind": "CRYPTO" if is_crypto_pair(t["symbol"]) else "SECURITY",
                "quoteMode": "MARKET", "quoteCcy": t["currency"],
                "providerId": "YAHOO", "providerSymbol": t["symbol"],
            },
            "activityType": "BUY", "activityDate": f"{t['date']}T00:00:00Z",
            "quantity": t["quantity"], "unitPrice": t["price"],
            "currency": t["currency"], "fee": "0", "isDraft": False,
            "comment": "Imported from Sure",
        })
        n += 1
    return n


def main(argv=None, env=None, opener=None, run=None, today=None):
    log = logger(TAG)
    cfg = Config.from_env(env)
    if today is None:
        today = datetime.date.today().isoformat()
    if not cfg.wf_password:
        log("FATAL WF_PASSWORD is unset")
        return 1
    if run is None:
        import subprocess

        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout

    wf = Wealthfolio(cfg.wf_url, opener=opener)
    try:
        wf.login(cfg.wf_password)
    except urllib.error.HTTPError as exc:
        log(f"FATAL login failed: {exc.code}")
        return 1

    accounts = {a["name"]: a for a in sure_accounts(cfg, run)}
    positions = sure_positions(cfg, run, cfg.backfill_from)
    cash = sure_cash(cfg, run, cfg.backfill_from)
    trades = sure_trades(cfg, run)

    # An account is transaction-tracked only when EVERY position it holds has a
    # real trade behind it. Mixing the two inside one account would be worse
    # than either: the positions without a trade would read as though they had
    # never been bought, i.e. as pure gain.
    latest = max((d for _, d in positions), default=None)
    held = {}
    for (name, date), pos in positions.items():
        if date == latest or cfg.backfill_from:
            held.setdefault(name, set()).update(p["symbol"] for p in pos)
    by_trade = {
        name: rows for name, rows in trades.items()
        if held.get(name) and held[name] <= {r["symbol"] for r in rows}
    }

    by_account = build_snapshots(positions, cash)

    imported = 0
    for name, snapshots in sorted(by_account.items()):
        if name in by_trade:
            continue  # handled below, from its real trades
        src = accounts.get(name)
        if not src:
            log(f"WARN {name} has holdings but no account row — skipped")
            continue
        account_type = ACCOUNT_TYPES.get(src["kind"])
        if not account_type:
            log(f"WARN {name} is a {src['kind']} — not an account type Wealthfolio has")
            continue
        account_id = ensure_account(
            wf, log, name, account_type, src["currency"],
            GROUPS.get(account_type, "Investments"), cfg.dry_run,
        )
        if not account_id:
            continue
        imported += import_snapshots(wf, log, account_id, snapshots, cfg.dry_run)

    # Accounts with a full set of real trades: TRANSACTIONS mode, real dates,
    # real prices — which is what makes TWR and IRR computable at all.
    for name, rows in sorted(by_trade.items()):
        src = accounts.get(name)
        if not src:
            continue
        account_type = ACCOUNT_TYPES.get(src["kind"], "SECURITIES")
        account_id = ensure_account(
            wf, log, name, account_type, src["currency"],
            GROUPS.get(account_type, "Investments"), cfg.dry_run,
            tracking_mode="TRANSACTIONS",
        )
        if account_id:
            imported += import_trades(wf, log, account_id, rows, cfg.dry_run)

    sync_goals(wf, log, sure_goals(cfg, run), cfg.dry_run)
    sync_alternatives(wf, log, sure_alternatives(cfg, run), today, cfg.dry_run)

    if not cfg.dry_run:
        # Refresh quotes so the new positions price immediately rather than
        # waiting for the server's own 4-hourly scheduler.
        wf.call("POST", "/market-data/sync", {"refetchAll": False})
    log(f"{'DRY RUN — ' if cfg.dry_run else ''}{imported} snapshot(s) imported "
        f"across {len(by_account)} account(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
