"""
Spending for journal-daily, from Sure's database (as postgres).

A day's spending = the money going out of the configured accounts on that
date (banks give dates, not times: no 04:00 shift), counting `standard`
transactions and `loan_payment`s (the mortgage counts) that are neither excluded
nor pending. Transfers between own accounts are `funds_movement` and stay out. Money coming back is shown apart,
and only refunds (REFUND_CATEGORIES): salary, Airbnb payouts, gifts and meal
vouchers are not spending's opposite.

Banks deliver late (2026-10: median 1.7 days, p90 6.5, p99 ~20), so the
journal re-reads the last CATCHUP_DAYS and marks a day younger than
SETTLED_DAYS as still syncing.
"""

from dataclasses import dataclass

from ..pg import psql_rows

CATCHUP_DAYS = 21
SETTLED_DAYS = 7
REFUND_CATEGORIES = ("Refunds", "I3 - Health", "I6 - Cancel")
SKIP_CATEGORIES = ("Investment Contributions",)  # savings, not spending
# Sure category name prefix ("0 - Groceries") -> emoji
CATEGORY_EMOJI = {"0": "🍽", "1": "🎭", "2": "🛍", "3": "🚕", "4": "💊", "5": "🧰", "6": "🧾",
                  "7": "🎁", "8": "🏠", "9": "🏦"}


@dataclass(frozen=True)
class Spend:
    joint: bool
    amount: float  # € out (> 0), or back (< 0)
    merchant: str
    category: str


def _sql_list(names):
    return ", ".join("'" + n.replace("'", "''") + "'" for n in names) or "NULL"


def day_spends(run, day, accounts, joint=(), db="sure_production", runuser="runuser", psql="psql"):
    """The day's Spends on `accounts` and the `joint` ones (Sure account names)."""
    rows = psql_rows(run, f"""
        SELECT a.name IN ({_sql_list(joint)}), e.amount, coalesce(m.name, e.name), coalesce(c.name, '')
        FROM entries e
        JOIN accounts a ON a.id = e.account_id
        JOIN transactions t ON t.id = e.entryable_id AND e.entryable_type = 'Transaction'
        LEFT JOIN categories c ON c.id = t.category_id
        LEFT JOIN merchants m ON m.id = t.merchant_id
        WHERE a.name IN ({_sql_list(tuple(accounts) + tuple(joint))})
          AND e.date = '{day.isoformat()}' AND t.kind IN ('standard', 'loan_payment') AND NOT e.excluded
          AND coalesce(t.extra->'enable_banking'->>'pending', '') <> 'true'
          AND coalesce(t.extra->'lunchflow'->>'pending', '') <> 'true'
        ORDER BY e.amount DESC, e.id
    """, db, runuser, psql)
    return [Spend(r[0] == "t", float(r[1]), r[2], r[3]) for r in rows]


def _eur(x):
    return f"{x:,.2f}".replace(",", " ").replace(".", ",") + " €"


def _emoji(category):
    if category.endswith("Groceries"):
        return "🛒"
    return CATEGORY_EMOJI.get(category[:1], "💳")


def spend_section(spends, age_days):
    """(heading suffix, lines) or None: `47,30 € · 👥 18,43 € en commun`, then one
    line per merchant, biggest first, the joint account's marked 👥, then
    `- ↩︎ **Remboursé** · 23,50 €`. `age_days` = days since the day."""
    out = [s for s in spends if s.amount > 0 and s.category not in SKIP_CATEGORIES]
    back = -sum(s.amount for s in spends if s.amount < 0 and s.category in REFUND_CATEGORIES)
    if not out and not back:
        return None
    merged = {}
    for s in out:
        key = (s.joint, s.merchant)
        total, n, cat = merged.get(key, (0, 0, s.category))
        merged[key] = (total + s.amount, n + 1, cat)
    mine = sum(s.amount for s in out if not s.joint)
    ours = sum(s.amount for s in out if s.joint)
    head = [_eur(mine)] if mine or not ours else []
    if ours:
        head.append(f"👥 {_eur(ours)} en commun")
    if age_days < SETTLED_DAYS:
        head.append("en cours de synchro")
    lines = []
    for (joint, merchant), (total, n, cat) in sorted(merged.items(), key=lambda kv: (kv[0][0], -kv[1][0])):
        lines.append(f"- {'👥 ' if joint else ''}{_emoji(cat)} **{merchant}** · {_eur(total)}"
                     + (f" ({n})" if n > 1 else ""))
    if back:
        lines.append(f"- ↩︎ **Remboursé** · {_eur(back)}")
    return " · ".join(head), lines
