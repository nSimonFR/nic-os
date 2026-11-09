---
name: rxresume
description: Read and update CVs and job-application tracking in the self-hosted Reactive Resume (v5) through its REST API — Nico's account or Alfie's. Use when asked to list or export a CV as PDF, look up or change the status of a job application (applied, interview, rejected…), or record a new application.
metadata:
  short-description: Reactive Resume v5 REST API (CVs + application tracker) for Nico and Alfie
---

# Reactive Resume

Self-hosted Reactive Resume v5 on rpi5. Two accounts, two keys, both brokered by Agent
Vault (agents only ever hold placeholders):

| Whose | Key variable | What lives there |
|---|---|---|
| Nico | `$RXRESUME_API_KEY` | his CV variants (career repo) |
| Alfie | `$RXRESUME_ALFIE_API_KEY` | her CVs, one copy per application (tag `candidature`), her application tracker |

Pick the account from who the request is about. Never cross them.

```bash
rxr() {  # rxr <nico|alfie> <METHOD> <path under /api/openapi> [json body] [extra curl args]
  ( set -a; . "${AGENT_VAULT_ENV:-/var/lib/agent-vault-hermes/proxy.env}"; set +a
    k=$RXRESUME_API_KEY; [ "$1" = alfie ] && k=$RXRESUME_ALFIE_API_KEY
    curl -sS --fail-with-body -m 300 --retry 2 --retry-delay 15 --retry-all-errors \
      -X "$2" "http://rxresume.home.arpa:13336/api/openapi$3" -H "x-api-key: $k" \
      ${4:+-H 'Content-Type: application/json' -d "$4"} "${@:5}" )
}
rxr alfie GET /resumes | jq -r '.[] | "\(.updatedAt[:10])  \(.name)  \(.tags)"'   # sanity check
```

`--retry` is only safe because the default calls above are reads; for a POST, drop it
(`rxr … POST …` then check before retrying — a re-POST duplicates).

## Recipes

```bash
rxr alfie GET /applications | jq -r '.[] | "\(.status)\t\(.company)\t\(.role)"'
rxr alfie POST /applications '{"company":"Greenly","role":"Climate Strategy Expert","status":"applied","sourceUrl":"https://…","notes":"…"}'
rxr alfie PUT  /applications/<id> '{"status":"interview"}'
rxr alfie GET "/resumes/<id>/pdf?target=resume" -o cv.pdf           # target=cover-letter for the letter
rxr nico  GET /resumes/<id> | jq '.data.basics'
```

Statuses seen working: `saved`, `applied`, `rejected`. `interview` and `offer` are the
expected others; check the response.
Before creating an application, list them and match on `sourceUrl`, then company + role:
Alfie may already have added it herself in the web UI.

## Rules

- **Alfie's data changes only when she asks** (Telegram), never on Nico's say-so alone for
  her CV content. Her CVs and cover letters are produced by the candidatures pipeline on
  Nico's Mac (one-page, her Canva template, language of the offer); don't regenerate them
  here, only read, export or track.
- **Nico's CVs**: résumés tagged `claude` are locked and generated from the career repo;
  untagged ones are his own. Never edit either through the API.
- PDF export is rate-limited (5 per window): on HTTP 429 the body's `reset` (ms) says when.
- The backend is socket-activated and sleeps after 10 idle minutes: the first call can take
  ~20 s or answer 502/503; the retries above cover it.
- Web UI for humans: `https://rpi5.gate-mintaka.ts.net/rxresume` (tailnet only). Password
  reset emails are not sent (no SMTP): a reset needs a DB-side token.
