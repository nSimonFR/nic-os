---
name: sure
description: Query and tidy the user's finances in Sure (self-hosted personal finance, source of truth for accounts and transactions) — net worth, balances, spending, searching transactions, budgets, re-categorizing a transaction. Use for "how much did I spend on…", "what's my net worth", or fixing a transaction's category.
homepage: https://github.com/we-promise/sure
metadata: {"openclaw":{"emoji":"💶","requires":{"bins":["curl","jq"]}}}
---

# Sure

```bash
SURE=http://sure.home.arpa:13334/sure/api/v1   # via Agent Vault; 127.0.0.1 bypasses it → 401
H=(-H "X-Api-Key: __sure_api_key__" -H "Accept: application/json")
curl -sS -m 90 "${H[@]}" "$SURE/balance_sheet" | jq .
```

API reference: `/etc/sure/openapi.json` (300 KB, query it with jq, paths start `/api/v1`):

```bash
jq -r '.paths | to_entries[] | .key as $p | .value | keys[] | select(. != "parameters") | "\(ascii_upcase) \($p)"' /etc/sure/openapi.json
jq '.paths["/api/v1/transactions"].get.parameters | map({name, description})' /etc/sure/openapi.json
```

- Sure sleeps when idle: the first call can take a minute or return a non-JSON page. Use `-m 90` and retry once.
- Compute with `amount_cents` (always positive) and `classification`; skip `transfer != null` in spending totals.
- `per_page` max 100; loop `page` up to `pagination.total_pages`.
- Links for the user: `https://rpi5.gate-mintaka.ts.net/sure/…`, never the API URL.
- Writes only when asked. `tag_ids` replaces the whole list.
- Never: `POST /sync` or `imports` (can kill a running import), `DELETE` unless explicitly asked, `chats` (paid AI).
