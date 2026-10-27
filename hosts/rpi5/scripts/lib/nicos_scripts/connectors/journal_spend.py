"""
Spending for journal-daily, from Sure's REST API (GET /api/v1/transactions,
docs/api/openapi.yaml in the Sure package) with a read-only API key.

A day's spending = the money going out of the configured accounts on that
date (banks give dates, not times: no 04:00 shift). Transfers between own
accounts stay out, except those to a loan account: the mortgage counts. The
API doesn't flag excluded or pending transactions, so both count; a settled
transaction replaces its pending copy and the catch-up re-reads the day.
The memo shows the totals only (personal, joint) and links to Sure's list
for the detail.

Banks deliver late (2026-10: median 1.7 days, p90 6.5, p99 ~20), so the
journal re-reads the last CATCHUP_DAYS and marks a day younger than
SETTLED_DAYS as still syncing.
"""

import urllib.parse
from dataclasses import dataclass

from ..httpjson import get_json

CATCHUP_DAYS = 21
SETTLED_DAYS = 7
SKIP_CATEGORIES = ("Investment Contributions",)  # savings, not spending


@dataclass(frozen=True)
class Spend:
    joint: bool
    amount: float  # € out (> 0), or back (< 0)
    merchant: str
    category: str


def _counts(t):
    transfer = t.get("transfer")
    return not transfer or (transfer.get("other_account") or {}).get("account_type") == "loan"


def day_spends(day, accounts, joint=(), url="http://127.0.0.1:13334/sure", key="", opener=None):
    """The day's Spends on `accounts` and the `joint` ones (Sure account names)."""
    names, spends, page = set(accounts) | set(joint), [], 1
    while True:
        q = urllib.parse.urlencode({"start_date": day.isoformat(), "end_date": day.isoformat(),
                                    "per_page": 100, "page": page})
        reply = get_json(f"{url}/api/v1/transactions?{q}", {"X-Api-Key": key, "Accept": "application/json"},
                         timeout=120, opener=opener)
        for t in reply.get("transactions", []):
            if t["account"]["name"] in names and _counts(t):
                spends.append(Spend(t["account"]["name"] in joint, -t["signed_amount_cents"] / 100,
                                    (t.get("merchant") or {}).get("name") or t["name"],
                                    (t.get("category") or {}).get("name") or ""))
        if page >= (reply.get("pagination") or {}).get("total_pages", 1):
            return sorted(spends, key=lambda s: -s.amount)
        page += 1


def _eur(x):
    return f"{x:,.2f}".replace(",", " ").replace(".", ",") + " €"


def detail_url(base, day, accounts):
    """Sure's transaction list for the day on those accounts."""
    q = [("q[start_date]", day.isoformat()), ("q[end_date]", day.isoformat())]
    q += [("q[accounts][]", a) for a in accounts]
    return f"{base}/transactions?{urllib.parse.urlencode(q)}"


def spend_section(spends, age_days, link=""):
    """(heading suffix, lines) or None: `47,30 € · 👥 18,43 € en commun`, the
    detail left to Sure behind `link`. `age_days` = days since the day."""
    out = [s for s in spends if s.amount > 0 and s.category not in SKIP_CATEGORIES]
    if not out:
        return None
    mine = sum(s.amount for s in out if not s.joint)
    ours = sum(s.amount for s in out if s.joint)
    head = [_eur(mine)] if mine or not ours else []
    if ours:
        head.append(f"👥 {_eur(ours)} en commun")
    if age_days < SETTLED_DAYS:
        head.append("en cours de synchro")
    return " · ".join(head), [f"[Détail dans Sure]({link})"] if link else []
