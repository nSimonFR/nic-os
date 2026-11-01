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

## The API reference

The full OpenAPI spec for the deployed version is at `/etc/sure/openapi.json`
(about 300 KB). Query the part you need with jq; never read the whole file.
Paths in the spec start with `/api/v1`, which `$SURE` already includes.

```bash
S=/etc/sure/openapi.json
jq -r '.paths | to_entries[] | .key as $p | .value | keys[] | select(. != "parameters") | "\(ascii_upcase) \($p)"' $S   # every endpoint
jq '.paths["/api/v1/transactions"].get.parameters | map({name, description})' $S                                        # an endpoint's filters
jq '.paths["/api/v1/transactions/{id}"].patch.requestBody.content["application/json"].schema' $S                       # a write's body
```

## Conventions

- **Amounts**: `amount` is a formatted string (`"€33.33"`). Compute with
  `amount_cents`, which is always positive, and `classification` (`expense` /
  `income`). `signed_amount_cents` is negative for an expense.
- **Transfers** between the user's own accounts have a non-null `transfer`. Leave
  them out of spending totals.
- **Categories** are numbered top-level groups (`0 - Food`, `2 - Essentials`, …)
  with subcategories (`0 - Food & Drink`). A transaction's `category` can be `null`
  (uncategorized).
- **Pagination**: `per_page` is capped at 100. Loop over `page` until
  `pagination.total_pages`. Asking for a page past the end returns the last page
  again.
- Currency is EUR, apart from a few crypto accounts held in USD.

Spending by category for a month: fetch every page of
`/transactions?type=expense&start_date=…&end_date=…&per_page=100`, then:

```bash
jq -s '[.[].transactions[] | select(.transfer == null)]
  | group_by(.category.name // "Uncategorized")
  | map({category: (.[0].category.name // "Uncategorized"), eur: (map(.amount_cents) | add / 100)})
  | sort_by(-.eur)' page1.json page2.json
```

## Writes — only when the user asks for that change

Edit a transaction with `PATCH $SURE/transactions/<id>`, fields nested under
`{"transaction":{…}}`. Look the ids up first (`categories`, `tags`, `merchants`),
then read the result back. Sending `tag_ids` **replaces** the whole tag list, so
send the existing ids plus the new one.

Never do the following, even if it looks like it would help:

- `POST /sync`, or anything else under `imports` or `import_sessions`. The bank
  connectors run on their own schedule, and a sync started in the middle of an
  import can kill it.
- `DELETE` a transaction, trade or tag, or `POST /transactions`, unless the user
  asks for it explicitly and names the transaction. Transactions imported by a
  connector belong to that connector.
- `chats` / `messages`: these run Sure's own AI, which is paid per call.
