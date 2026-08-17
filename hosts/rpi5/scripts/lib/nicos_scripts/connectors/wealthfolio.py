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

GOALS ARE NOT MIRRORED. They were, briefly, and it did not survive contact:
Wealthfolio caps an account's allocation across all goals at 100%, so the
mirrored goal and the one nSimon made in the app fought over the same five
accounts and one of them was always broken. Goals are his, owned in Wealthfolio,
and Sure's stay in Sure. Nothing here touches /goals.

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
  (Cash, savings and the credit card are NOT mirrored — that is Sure's job, and
  a second copy is a second place for the same number to be slightly wrong in.)
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
# Investments only. Depository and CreditCard are deliberately absent: current
# accounts, savings and the card are Sure's job, and duplicating them here bought
# a second place for the same numbers to be slightly wrong in. Wealthfolio holds
# what it is good at — positions, and the property/loan pair.
ACCOUNT_TYPES = {
    "Investment": "SECURITIES",
    "Crypto": "CRYPTOCURRENCY",
}

# Only for symbols the CRYPTO: rule below gets wrong. Empty on purpose — every
# crypto in the data maps correctly by rule, and a table that restates the rule
# is a table that drifts from it.
SYMBOL_OVERRIDES = {}

# Sure account name -> the Wealthfolio account it is folded into.
#
# Sure models a crypto wallet as one account PER TOKEN, so a single Ledger
# address shows up four times (ETH, Stader, Stader ETHx, the staking position)
# and the portfolio reads as seven wallets when there are two. Grouping is by
# custodian, which is the thing that actually exists.
#
# The address is the evidence: 0x38...b5b7 appears in four of these names, so
# they are provably one wallet. The Ledger/Kraken split for the rest, and which
# custodian holds bc1q...k6aq, came from nSimon — Sure records neither, and it
# truncates the Bitcoin address past the character that would distinguish his
# two bc1q wallets.
WALLET_GROUPS = {
    "Bitcoin (bc1q...k6aq)": "Ledger",
    "Ethereum (0x38...b5b7)": "Ledger",
    "Stader (0x38...b5b7)": "Ledger",
    "Stader ETHx (0x38...b5b7)": "Ledger",
    "ETH (Stader Staking)": "Ledger",
    "Ledger Staking": "Ledger",
    "Ethereum (0x21...756F)": "Kraken Wallet",
}


# Cost basis nSimon reconstructed from his own exchange exports, for positions
# where Sure has none. Keyed (grouped account, symbol) -> total paid IN THE
# POSITION'S OWN QUOTE CURRENCY; the per-unit avgCost is derived from whatever
# quantity is held, so it stays right as the position moves.
#
# Quote currency, NOT euros, and that bit is easy to get wrong: avgCost is
# denominated in the position's currency, so feeding a EUR figure to a USD-quoted
# pair had Wealthfolio read €195 as $195 and report a €13 loss on a position
# that is actually up. Converted once, at the rate on each purchase date, rather
# than at today's — the receipts are euros and the euros were spent then.
#
# NOT in Sure, deliberately. Sure only ever writes cost_basis_source
# 'calculated' — a hand-written 'manual' row is a value its own code does not
# produce, and its next CoinStats resync would recompute over it with nothing
# reporting the loss. Here it is versioned, reviewed and survives.
#
# BTC €195 = two purchases, both later withdrawn to a self-custody wallet:
#   2024-06-24  0.00076430 BTC  €45.00   } Finary export, account emptied
#   2024-06-25  0.00086848 BTC  €50.00   } 2024-09-21, reconciles to 1.4e-7
#   2024-06-01  0.00151000 BTC  €100.00    second platform (recurring buy)
# Acquired 0.00314474 against 0.00287313 held; the 0.00027 gap is network fees,
# which are part of the cost, so the full €195 stands. In USD, at EURUSD on the
# day of each purchase: €100 x 1.08354 (2024-06-01) + €95 x 1.06878 (2024-06-24
# and -25) = $209.88.
COST_BASIS_OVERRIDES = {
    ("Ledger", "BTC-USD"): 209.88,
    # ETH. Most of it was never bought, which is why no export ever reconciled:
    # 5000 FLT arrived as an airdrop on 2024-05-18, was claimed on 2024-07-17,
    # sold on 2024-07-19 for 0.3691821 ETH, staked, and came back as 0.37155146
    # ETH — roughly 0.37 of the 0.481 held, at zero acquisition cost. Traced
    # on-chain across both wallets with the Etherscan key in agenix.
    #
    # Actually paid, €228.05 in three lots, converted at EURUSD on each date:
    #   2024-05-18  €10.00 x 1.08678 = $10.87   exchange buy, 0.003 ETH
    #   2024-06-24  €95.00 x 1.06878 = $101.53  Finary, withdrawn 2024-09-21
    #   2024-09-28  €123.05 x 1.11772 = $137.53 XLM converted to 0.05074 ETH
    # = $249.74 total, split by holding because the coins are fungible and moved
    # between both wallets: Ledger 92.3%, Kraken Wallet 7.7%. Average cost is
    # also what French crypto tax uses, so this matches how it will be declared.
    ("Ledger", "ETH-USD"): 230.48,
    ("Kraken Wallet", "ETH-USD"): 19.26,
}


def wallet_group(name):
    """The account a Sure account is folded into — itself, if ungrouped."""
    return WALLET_GROUPS.get(name, name)


def group_accounts(accounts):
    """Sure accounts keyed by the Wealthfolio account they become.

    A group's currency is the one MOST of its members use, not the first one
    seen: five of the six Ledger accounts are USD and "Ledger Staking" is EUR,
    so picking arbitrarily would flip the whole wallet's denomination depending
    on sort order. The positions carry their own currency regardless — this is
    only what the account is labelled in.
    """
    groups = {}
    for a in accounts:
        groups.setdefault(wallet_group(a["name"]), []).append(a)
    out = {}
    for name, members in groups.items():
        counts = {}
        for m in members:
            counts[m["currency"]] = counts.get(m["currency"], 0) + 1
        currency = max(sorted(counts), key=lambda c: counts[c])
        out[name] = {**members[0], "name": name, "currency": currency}
    return out


def apply_cost_basis_overrides(account, rows):
    """Fill in a basis Sure does not have, from COST_BASIS_OVERRIDES.

    Only ever fills a GAP — a position Sure already prices keeps Sure's number,
    so this cannot quietly diverge from the source of truth.
    """
    for pos in rows:
        total = COST_BASIS_OVERRIDES.get((account, pos["symbol"]))
        qty = float(pos["quantity"] or 0)
        if total is None or "avgCost" in pos or not qty:
            continue
        pos["avgCost"] = f"{total / qty:.8f}"
    return rows


def merge_positions(rows):
    """Sum positions that share a symbol after grouping.

    Necessary, not defensive: a Ledger wallet holds ETH at the 0x38 address AND
    ETH via Ledger Staking, which are two Sure accounts and one holding. Left
    unmerged the snapshot carries the symbol twice and the second silently wins.

    Cost basis is summed as MONEY (quantity x avgCost) and re-divided, so the
    result is a weighted average rather than the average of two averages. A
    position missing avgCost makes the whole merged basis unknown — averaging
    over the ones that have it would understate what was paid.
    """
    merged = {}
    for pos in rows:
        cur = merged.get(pos["symbol"])
        if cur is None:
            merged[pos["symbol"]] = dict(pos)
            continue
        qty = float(cur["quantity"]) + float(pos["quantity"])
        if "avgCost" in cur and "avgCost" in pos:
            cost = (float(cur["quantity"]) * float(cur["avgCost"])
                    + float(pos["quantity"]) * float(pos["avgCost"]))
            cur["avgCost"] = f"{cost / qty:.8f}" if qty else cur["avgCost"]
        else:
            cur.pop("avgCost", None)
        cur["quantity"] = f"{qty:.8f}"
    return list(merged.values())

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
        # Crypto used to be excluded here, because Sure had no cost basis for
        # it and sending 0 renders as a 100% gain. It has one now — written from
        # nSimon's exchange exports and the on-chain trace, marked manual and
        # LOCKED so a CoinStats resync cannot recompute over it — so Sure is the
        # source for crypto as for everything else, and COST_BASIS_OVERRIDES is
        # only the fallback for what Sure still does not know.
        if basis:
            pos["avgCost"] = basis
        # `mic` is read but deliberately NOT sent. Sure's exchange_operating_mic
        # is not always a MIC: the German listings carry the string "GER"
        # (SXRT.DE, MAGR.DE), and passing that through pins the asset to a
        # non-existent exchange, so Yahoo never quotes it and the position
        # values at zero — silently, since the quantity is still right.
        # Wealthfolio resolves the real MIC from the symbol suffix on its own
        # (.DE -> XETR, verified against /snapshots/import/check), which is
        # strictly better than anything Sure can tell us.
        out.setdefault((wallet_group(name.strip()), date), []).append(pos)
    # k is (account, date) — the override is keyed on the account alone.
    return {k: apply_cost_basis_overrides(k[0], merge_positions(v)) for k, v in out.items()}


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
        out.setdefault(wallet_group(name.strip()), []).append({
            "symbol": symbol, "date": date, "quantity": qty, "price": price,
            "currency": "USD" if is_crypto_pair(symbol) else ccy,
        })
    return out


def sure_alternatives(cfg, run):
    """Property and Loan — Wealthfolio alternative assets, not accounts.

    Carries the ORIGIN as well as the current value: the earliest balance Sure
    recorded, and its amount. Without it the flat and the mortgage each show a
    number with no history, so the app cannot say the property is up EUR 13.5k
    or that EUR 10.8k of the loan is repaid — which is most of why they are
    worth mirroring at all.

    Sure has no purchase_price/purchase_date column on either (properties has
    year_built and an AVM provider; loans has initial_balance, but only the
    loan). The first balance row is the same fact recorded differently, and it
    exists for both.
    """
    rows = pg(cfg, run, """
        SELECT a.name, a.accountable_type, a.currency, a.balance,
               (SELECT b.date::text FROM balances b WHERE b.account_id = a.id
                ORDER BY b.date LIMIT 1),
               (SELECT b.balance::text FROM balances b WHERE b.account_id = a.id
                ORDER BY b.date LIMIT 1)
        FROM accounts a
        WHERE a.accountable_type IN ('Property', 'Loan') AND a.status <> 'draft'
        ORDER BY a.accountable_type
    """)
    kinds = {"Property": "property", "Loan": "liability"}
    return [
        {
            "name": n.strip(), "kind": kinds[t], "currency": c, "value": bal,
            "start_date": first_date or None,
            "start_value": first_amount or None,
        }
        for n, t, c, bal, first_date, first_amount in rows
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
        # HOLDINGS unless the caller has real trades to offer. TRANSACTIONS on
        # an account with no trade history would silently zero every position.
        "trackingMode": tracking_mode,
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


def sure_alternative_history(cfg, run):
    """Month-end value of each Property/Loan, from Sure's daily balances.

    Month-end rather than daily: 32 points instead of 928, which is the same
    curve at this resolution — a mortgage amortises monthly and the flat is
    revalued a few times a year — for a thirtieth of the API calls.
    """
    rows = pg(cfg, run, """
        SELECT a.name, max(b.date)::text,
               (array_agg(b.balance ORDER BY b.date DESC))[1]::text
        FROM balances b JOIN accounts a ON a.id = b.account_id
        WHERE a.accountable_type IN ('Property', 'Loan') AND a.status <> 'draft'
        GROUP BY a.name, to_char(b.date, 'YYYY-MM')
        ORDER BY a.name, max(b.date)
    """)
    out = {}
    for name, date, value in rows:
        out.setdefault(name.strip(), []).append((date, value))
    return out


def sync_alternatives(wf, log, alternatives, today, dry_run, history=None):
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
        body = {
            "kind": alt["kind"], "name": alt["name"], "currency": alt["currency"],
            "currentValue": alt["value"], "valueDate": today,
        }
        if alt.get("start_value") and alt.get("start_date"):
            body["purchasePrice"] = alt["start_value"]
            body["purchaseDate"] = alt["start_date"]
        created = wf.call("POST", "/alternative-assets", body)
        ids[alt["kind"]] = created["assetId"]
        log(f"created {alt['kind']} {alt['name']}")
        # Backfill the curve between purchase and today. Only on creation: the
        # points do not change once written, and re-pushing 32 valuations every
        # morning would be 32 calls to say nothing.
        for date, value in (history or {}).get(alt["name"], []):
            wf.call("PUT", f"/alternative-assets/{ids[alt['kind']]}/valuation",
                    {"value": value, "date": date})
        if (history or {}).get(alt["name"]):
            log(f"  backfilled {len(history[alt['name']])} month-end valuations")

    if not dry_run and "liability" in ids and "property" in ids:
        wf.call("POST", f"/alternative-assets/{ids['liability']}/link-liability",
                {"targetAssetId": ids["property"]})
        # link-liability REPLACES the asset's metadata object rather than
        # merging into it, so purchase_price/purchase_date are collateral: the
        # link returns 204 and the origin is silently gone. Verified against the
        # running server — metadata goes from {purchase_date, purchase_price} to
        # {linked_asset_id}. Putting them back afterwards sticks, and the link
        # survives it.
        origin = next((a for a in alternatives if a["kind"] == "liability"), None)
        if origin and origin.get("start_value") and origin.get("start_date"):
            wf.call("PUT", f"/alternative-assets/{ids['liability']}/metadata",
                    {"metadata": {"purchase_price": origin["start_value"],
                                  "purchase_date": origin["start_date"]}})
        log("linked liability -> property")


def build_snapshots(positions):
    """One snapshot list per account, sorted by date.

    cashBalances stays empty: cash accounts are not mirrored at all, and an
    investment account's cash sleeve is not something Sure tracks separately.
    """
    by_account = {}
    for (name, date), pos in positions.items():
        by_account.setdefault(name, []).append({
            "date": date, "positions": pos, "cashBalances": {},
        })
    for snapshots in by_account.values():
        snapshots.sort(key=lambda s: s["date"])
    return by_account


def sync_portfolios(wf, log, members, dry_run):
    """One portfolio per account group, so the app has the same split as the sidebar.

    Derived rather than configured: the grouping already exists (GROUPS), and a
    second hand-maintained list of which account belongs where is a list that
    drifts. A portfolio with no accounts is rejected by the server, so empty
    groups are skipped rather than created and left dangling.
    """
    existing = {p["name"]: p for p in (wf.call("GET", "/portfolios") or [])}
    for name, account_ids in sorted(members.items()):
        if not account_ids:
            continue
        body = {"name": name, "accountIds": sorted(account_ids),
                "description": "Mirrored from Sure"}
        if name in existing:
            if not dry_run:
                # `id` in the BODY as well as the path — the handler
                # deserialises a full Portfolio and 422s without it.
                wf.call("PUT", f"/portfolios/{existing[name]['id']}",
                        {**body, "id": existing[name]["id"]})
            continue
        if dry_run:
            log(f"DRY would create portfolio {name} ({len(account_ids)} accounts)")
            continue
        wf.call("POST", "/portfolios", body)
        log(f"created portfolio {name} ({len(account_ids)} accounts)")


def post_activity(wf, body):
    """POST one activity, treating "already there" as success.

    Activities are NOT upserted the way snapshots are. The server detects a
    duplicate and answers 400, so the second run of a timer would abort the
    whole account on its first re-post. That 400 IS the idempotency guarantee —
    it means the row exists and matches — so it is swallowed rather than
    guarded against with a read-then-write race.
    """
    try:
        wf.call("POST", "/activities", body)
        return True
    except urllib.error.HTTPError as exc:
        if exc.code == 400 and "Duplicate activity" in exc.read().decode(errors="replace"):
            return False
        raise


def import_trades(wf, log, account_id, trades, dry_run):
    """Real buys, at their real dates and prices.

    A DEPOSIT precedes them covering the total cost: in TRANSACTIONS mode a BUY
    with no cash behind it drives the account's cash negative, and Sure does not
    model the transfer that funded the purchase. Dated on the first buy so it
    never lands after the money is spent.
    """
    if dry_run:
        log(f"DRY would import {len(trades)} trade(s)")
        return 0

    first = min(t["date"] for t in trades)
    funding = sum(float(t["quantity"]) * float(t["price"]) for t in trades)
    post_activity(wf, {
        "accountId": account_id, "activityType": "DEPOSIT",
        "activityDate": f"{first}T00:00:00Z", "amount": round(funding, 2),
        "currency": trades[0]["currency"], "isDraft": False,
        "comment": "Opening balance imported from Sure",
    })
    n = 0
    for t in trades:
        n += post_activity(wf, {
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

    accounts = group_accounts(sure_accounts(cfg, run))
    positions = sure_positions(cfg, run, cfg.backfill_from)
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

    by_account = build_snapshots(positions)

    imported = 0
    members = {}
    account_ids = {}
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
        members.setdefault(GROUPS.get(account_type, "Investments"), []).append(account_id)
        account_ids[name] = account_id
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
            members.setdefault(GROUPS.get(account_type, "Investments"), []).append(account_id)
            account_ids[name] = account_id
            imported += import_trades(wf, log, account_id, rows, cfg.dry_run)

    sync_portfolios(wf, log, members, cfg.dry_run)
    sync_alternatives(wf, log, sure_alternatives(cfg, run), today, cfg.dry_run,
                      history=sure_alternative_history(cfg, run))

    if not cfg.dry_run:
        # Refresh quotes so the new positions price immediately rather than
        # waiting for the server's own 4-hourly scheduler.
        wf.call("POST", "/market-data/sync", {"refetchAll": False})
    log(f"{'DRY RUN — ' if cfg.dry_run else ''}{imported} snapshot(s) imported "
        f"across {len(by_account)} account(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
