# Ghostfolio API Examples

These examples assume:

```bash
export GHOSTFOLIO_BASE_URL="http://127.0.0.1:3333"
export GHOSTFOLIO_TIMEZONE="Europe/Paris"
export GHOSTFOLIO_TOKEN="..."
```

## Verify auth exchange and endpoint statuses quickly

```bash
AUTH_TOKEN=$(curl -fsS "$GHOSTFOLIO_BASE_URL/api/v1/auth/anonymous" \
  -H 'Content-Type: application/json' \
  --data "{\"accessToken\":\"$GHOSTFOLIO_TOKEN\"}" \
| jq -r '.authToken')

for ep in /api/v2/portfolio/performance /api/v1/portfolio/holdings /api/v1/portfolio/dividends; do
  code=$(curl -s -o /tmp/gf_resp.json -w '%{http_code}' "$GHOSTFOLIO_BASE_URL$ep" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Accept: application/json' \
    -H "x-ghostfolio-timezone: $GHOSTFOLIO_TIMEZONE")
  echo "$ep -> $code"
done
```

## Demonstrate why direct bearer may fail

```bash
curl -s -o /tmp/gf_direct.json -w '%{http_code}\n' \
  "$GHOSTFOLIO_BASE_URL/api/v1/portfolio/holdings" \
  -H "Authorization: Bearer $GHOSTFOLIO_TOKEN" \
  -H 'Accept: application/json'
# Expected in many setups: 401
```
