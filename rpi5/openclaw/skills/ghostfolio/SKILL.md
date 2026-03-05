---
name: ghostfolio
description: Manage and query Ghostfolio portfolio data (performance, holdings, dividends) using the API with the required anonymous access-token exchange flow.
metadata: {"openclaw":{"emoji":"👻","requires":{"env":["GHOSTFOLIO_TOKEN"]},"primaryEnv":"GHOSTFOLIO_TOKEN"}}
---

# Ghostfolio

Use this skill when the user asks about Ghostfolio portfolio metrics, holdings, dividends, or API troubleshooting.

## Required Auth Flow (important)

Protected endpoints may return `401` if you send the long-lived access token directly as a Bearer token.

Use this two-step flow:

1. Exchange access token via `POST /api/v1/auth/anonymous`
2. Use returned `authToken` JWT as `Authorization: Bearer <authToken>` for protected endpoints

## Environment Variables

```bash
# Local service usually works without DNS.
export GHOSTFOLIO_BASE_URL="http://127.0.0.1:3333"
# Example remote URL (optional):
# export GHOSTFOLIO_BASE_URL="https://rpi5.gate-mintaka.ts.net:8444"

# Long-lived token supplied by user/admin.
export GHOSTFOLIO_TOKEN="..."

# Recommended to avoid timezone-dependent surprises in responses.
export GHOSTFOLIO_TIMEZONE="Europe/Paris"
```

## Safe Curl + jq Templates

### 1) Exchange access token for JWT

```bash
AUTH_JSON=$(curl -fsS "$GHOSTFOLIO_BASE_URL/api/v1/auth/anonymous" \
  -H 'Content-Type: application/json' \
  --data "{\"accessToken\":\"$GHOSTFOLIO_TOKEN\"}")

AUTH_TOKEN=$(printf '%s' "$AUTH_JSON" | jq -r '.authToken')

if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" = "null" ]; then
  echo "Failed to obtain authToken" >&2
  printf '%s\n' "$AUTH_JSON" | jq . >&2
  exit 1
fi
```

### 2) Portfolio performance (`/api/v2/portfolio/performance`)

```bash
curl -fsS "$GHOSTFOLIO_BASE_URL/api/v2/portfolio/performance" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Accept: application/json' \
  -H "x-ghostfolio-timezone: $GHOSTFOLIO_TIMEZONE" \
| jq .
```

### 3) Holdings (`/api/v1/portfolio/holdings`)

```bash
curl -fsS "$GHOSTFOLIO_BASE_URL/api/v1/portfolio/holdings" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Accept: application/json' \
  -H "x-ghostfolio-timezone: $GHOSTFOLIO_TIMEZONE" \
| jq .
```

### 4) Dividends (`/api/v1/portfolio/dividends`)

```bash
curl -fsS "$GHOSTFOLIO_BASE_URL/api/v1/portfolio/dividends" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Accept: application/json' \
  -H "x-ghostfolio-timezone: $GHOSTFOLIO_TIMEZONE" \
| jq .
```

## Practical one-shot helper

```bash
GHOSTFOLIO_BASE_URL="${GHOSTFOLIO_BASE_URL:-http://127.0.0.1:3333}"
GHOSTFOLIO_TIMEZONE="${GHOSTFOLIO_TIMEZONE:-Europe/Paris}"

AUTH_TOKEN=$(curl -fsS "$GHOSTFOLIO_BASE_URL/api/v1/auth/anonymous" \
  -H 'Content-Type: application/json' \
  --data "{\"accessToken\":\"$GHOSTFOLIO_TOKEN\"}" \
| jq -r '.authToken')

for endpoint in \
  /api/v2/portfolio/performance \
  /api/v1/portfolio/holdings \
  /api/v1/portfolio/dividends
 do
  echo "=== $endpoint ==="
  curl -fsS "$GHOSTFOLIO_BASE_URL$endpoint" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Accept: application/json' \
    -H "x-ghostfolio-timezone: $GHOSTFOLIO_TIMEZONE" \
  | jq .
 done
```

## Troubleshooting

- `401 Unauthorized`
  - Most common cause: using the long-lived access token directly as Bearer.
  - Fix: redo `/api/v1/auth/anonymous` exchange and use returned `authToken`.
  - If still failing, JWT may be expired; exchange again.

- `403 Forbidden`
  - Token is valid but does not grant access to requested portfolio resources.
  - Verify the access token belongs to the expected Ghostfolio account/environment.

- Missing/incorrect timezone behavior
  - Add `x-ghostfolio-timezone: Europe/Paris` (or user timezone) on requests.
  - Inconsistent date-boundary outputs often come from missing timezone header.

- Connectivity issues
  - Prefer local base URL first: `http://127.0.0.1:3333`
  - Remote TLS path can work too (example): `https://rpi5.gate-mintaka.ts.net:8444`
  - For self-signed/local certs during diagnostics, temporary `curl -k` may help.

## Safety Notes

- Never print or commit real tokens in logs/docs.
- Keep `GHOSTFOLIO_TOKEN` and exchanged `authToken` in env/shell memory only.
- Prefer `curl -fsS` so HTTP/API errors surface clearly in automation.
