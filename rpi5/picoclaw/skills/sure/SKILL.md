---
name: sure
description: Get reports and account / transaction data from the Sure personal finance board
homepage: https://sure.am
metadata: {"openclaw":{"emoji":"📈","requires":{"env":["SURE_API_KEY"]},"primaryEnv":"SURE_API_KEY"}}
---

# Sure Skill

Use this skill when the user asks about their **Sure** personal finance board: balances, accounts, transactions, recent spending, or API connectivity.

## Setup

1. Open your Sure instance, for example: `https://localhost:3000`
2. Go to **Settings → API key**
3. Export your API key and base URL:

```bash
export SURE_API_KEY="YOUR_API_KEY"
```

Example:

```bash
# Optional remote example:
# export SURE_BASE_URL="https://sure.example.com"
export SURE_API_KEY="..."
```

## Auth header

Base URL default:

```bash
export SURE_BASE_URL="${SURE_BASE_URL:-http://127.0.0.1:3000}"
```

Reuse this in commands:

```bash
AUTH=(-H "X-Api-Key: $SURE_API_KEY" -H "Content-Type: application/json")
```

## Quick connectivity check

```bash
curl -fsS "${AUTH[@]}" "$SURE_BASE_URL/api/v1/accounts" | jq '.pagination'
```

If this fails:
- verify `SURE_BASE_URL`
- verify the API key is valid
- make sure the URL includes scheme (`https://...`)

## Accounts

List accounts:

```bash
curl -fsS "${AUTH[@]}" "$SURE_BASE_URL/api/v1/accounts" | jq .
```

Compact account summary:

```bash
curl -fsS "${AUTH[@]}" "$SURE_BASE_URL/api/v1/accounts" \
  | jq -r '.accounts[] | "\(.name) | \(.balance) | \(.currency) | \(.account_type)"'
```

Accounts with pagination:

```bash
curl -fsS "${AUTH[@]}" "$SURE_BASE_URL/api/v1/accounts?page=1&per_page=100" | jq .
```

Useful account fields commonly returned:
- `id`
- `name`
- `balance`
- `currency`
- `classification`
- `account_type`

## Transactions

List recent transactions for one account:

```bash
curl -fsS "${AUTH[@]}" \
  "$SURE_BASE_URL/api/v1/transactions?account_id=123&per_page=25" | jq .
```

Filter transactions by date:

```bash
curl -fsS "${AUTH[@]}" \
  "$SURE_BASE_URL/api/v1/transactions?start_date=2026-03-01&end_date=2026-03-31&per_page=100" | jq .
```

Filter expenses only:

```bash
curl -fsS "${AUTH[@]}" \
  "$SURE_BASE_URL/api/v1/transactions?type=expense&per_page=100" | jq .
```

Search transactions:

```bash
curl -fsS "${AUTH[@]}" \
  "$SURE_BASE_URL/api/v1/transactions?search=carrefour&per_page=50" | jq .
```

Compact transaction summary:

```bash
curl -fsS "${AUTH[@]}" \
  "$SURE_BASE_URL/api/v1/transactions?per_page=25" \
  | jq -r '.transactions[] | "\(.date) | \(.name) | \(.amount) | \(.account.name)"'
```

Useful transaction filters:
- `account_id`
- `account_ids`
- `category_id`
- `merchant_id`
- `start_date`
- `end_date`
- `min_amount`
- `max_amount`
- `type` (`income` or `expense`)
- `search`
- `page`
- `per_page`

## Practical reporting examples

Net worth-style account snapshot:

```bash
curl -fsS "${AUTH[@]}" "$SURE_BASE_URL/api/v1/accounts?per_page=100" \
  | jq '{count: (.accounts | length), accounts: [.accounts[] | {name, balance, currency, classification, account_type}]}'
```

Recent expenses this month:

```bash
curl -fsS "${AUTH[@]}" \
  "$SURE_BASE_URL/api/v1/transactions?type=expense&start_date=$(date +%Y-%m-01)&per_page=100" \
  | jq -r '.transactions[] | "\(.date) | \(.name) | \(.amount)"'
```

Top merchants in a date range:

```bash
curl -fsS "${AUTH[@]}" \
  "$SURE_BASE_URL/api/v1/transactions?start_date=2026-03-01&end_date=2026-03-31&per_page=100" \
  | jq -r '.transactions | group_by(.merchant.name // "Unknown") | map({merchant: (.[0].merchant.name // "Unknown"), count: length}) | sort_by(-.count) | .[] | "\(.merchant): \(.count)"'
```

## Notes

- Sure is an open-source personal finance platform: <https://sure.am>
- API docs indicate the main REST endpoints are under `/api/v1/...`
- Use `jq` for filtering and concise summaries in agent workflows
- Prefer read-only queries unless the user explicitly asks for mutations

## Troubleshooting

`401 Unauthorized`
- API key missing or invalid

`404 Not Found`
- wrong base URL or wrong path

TLS / certificate issues
- verify the Sure instance URL and certificate chain

Empty results
- widen date range or increase `per_page`
