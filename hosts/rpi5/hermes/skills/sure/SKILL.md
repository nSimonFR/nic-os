---
name: sure
description: Query and tidy the user's finances in Sure (self-hosted personal finance, the source of truth for accounts and transactions) — net worth, balances, spending by category or merchant, searching transactions, budgets, and re-categorizing or annotating a transaction. Use for "how much did I spend on…", "what's my net worth", "find the Carrefour payment", or fixing a transaction's category.
homepage: https://github.com/we-promise/sure
metadata: {"openclaw":{"emoji":"💶","requires":{"bins":["curl","jq"]}}}
---

# Sure

Sure is the user's personal-finance app: bank accounts (Sumeria, SG, Swile…),
investments, crypto, the flat and its loan. Bank connectors import transactions
continuously; this skill reads them and fixes the odd one by hand.

Wealthfolio (your `wealthfolio` MCP) is a read-only **mirror** of Sure's investments.
For anything that isn't portfolio performance, ask Sure.

## Setup

Call the API at **`http://sure.home.arpa:13334/sure/api/v1`**, a loopback alias
routed through Agent Vault (your `HTTP_PROXY`), which swaps the placeholder
`__sure_api_key__` for the real key. You never hold the key. Do not use
`127.0.0.1` or `localhost`: they bypass the proxy, and Sure answers 401.

```bash
SURE=http://sure.home.arpa:13334/sure/api/v1
H=(-H "X-Api-Key: __sure_api_key__" -H "Accept: application/json")
curl -sS -m 60 "${H[@]}" "$SURE/usage" | jq .   # sanity check: key "rpi5", scope read_write
```

Links for the user go to the web UI, **`https://rpi5.gate-mintaka.ts.net/sure`**
(e.g. `/transactions?q[start_date]=2026-10-01&q[end_date]=2026-10-31`). The API
URL above only resolves on rpi5; never send it.

## Conventions

- **Amounts**: `amount` is a formatted string (`"€33.33"`). Compute with
  `amount_cents`, which is always positive, and `classification` (`expense` /
  `income`). `signed_amount_cents` is negative for an expense.
- **Transfers** between the user's own accounts have a non-null `transfer`. Leave
  them out of spending totals.
- **Categories** are numbered top-level groups (`0 - Food`, `2 - Essentials`, …)
  with subcategories (`0 - Food & Drink`). A transaction's `category` can be `null`
  (uncategorized).
- **Pagination**: list endpoints return `pagination:{page, per_page, total_count,
  total_pages}`, with `per_page` capped at 100. Loop over `page` until
  `total_pages`. Asking for a page past the end returns the last page again.
- Currency is EUR, apart from a few crypto accounts held in USD.

## Read

```bash
# Net worth, assets, liabilities
curl -sS "${H[@]}" "$SURE/balance_sheet" | jq '{net_worth: .net_worth.formatted, assets: .assets.formatted, liabilities: .liabilities.formatted}'

# Accounts and balances
curl -sS "${H[@]}" "$SURE/accounts" | jq -r '.accounts[] | [.name, .account_type, .balance] | @tsv'

# Transactions, filtered. Filters: start_date, end_date (YYYY-MM-DD), type=expense|income,
# account_id, category_id, merchant_id, tag_ids[], min_amount, max_amount,
# search (matches name, notes and merchant, case-insensitive)
curl -sS "${H[@]}" "$SURE/transactions?start_date=2026-10-01&end_date=2026-10-31&type=expense&per_page=100&page=1" \
  | jq -r '.transactions[] | [.date, .amount, .name, .account.name, (.category.name // "—")] | @tsv'

# One transaction
curl -sS "${H[@]}" "$SURE/transactions/<id>" | jq .
```

Spending by category for a month: fetch every page of `type=expense`, drop
`transfer != null`, then group:

```bash
jq -s '[.[].transactions[] | select(.transfer == null)]
  | group_by(.category.name // "Uncategorized")
  | map({category: (.[0].category.name // "Uncategorized"), eur: (map(.amount_cents) | add / 100)})
  | sort_by(-.eur)' page1.json page2.json
```

Other read endpoints, all `GET`: `categories`, `merchants`, `tags`, `budgets`
(one per month), `budget_categories`, `recurring_transactions`, `holdings`,
`trades`, `valuations`, `balances`, `transfers`, `syncs/latest`.

## Write — only when the user asks for that change

Updates take a `PATCH` with the fields nested under `transaction`. Look the ids up
first (`categories`, `tags`, `merchants`), then read the result back:

```bash
curl -sS -X PATCH "${H[@]}" -H "Content-Type: application/json" "$SURE/transactions/<id>" \
  -d '{"transaction":{"category_id":"<category id>","notes":"…"}}' | jq '{name, category: .category.name, notes}'
```

Writable fields: `category_id`, `merchant_id`, `notes`, `name`, `date`, `tag_ids`.
Sending `tag_ids` **replaces** the whole tag list, so send the existing ids plus the
new one.

Never do the following, even if it looks like it would help:

- `POST /sync`, or anything else under `imports` or `import_sessions`. The bank
  connectors run on their own schedule, and a sync started in the middle of an
  import can kill it.
- `DELETE` a transaction, trade or tag, or `POST /transactions`, unless the user
  asks for it explicitly and names the transaction. Transactions imported by a
  connector belong to that connector.
- `chats` / `messages`: these run Sure's own AI, which is paid per call.
