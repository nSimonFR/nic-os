---
name: rxresume
description: Read and update CVs, cover letters and job-application tracking in the self-hosted Reactive Resume (v5 or v6) through its REST API or MCP — Nico's account or Alfie's. Use when asked to list or export a CV or cover letter as PDF, look up or change the status of a job application (applied, interview, rejected/closed…), or record a new application.
metadata:
  short-description: Reactive Resume REST API / MCP (CVs, letters, application tracker) for Nico and Alfie
---

# Reactive Resume

Self-hosted Reactive Resume on rpi5: v5.2 until the upgrade to v6.1 (nic-os PR #985), so
check which one answers before writing. Two accounts, two keys, both brokered by Agent
Vault (agents only ever hold placeholders):

| Whose | Key variable | What lives there |
|---|---|---|
| Nico | `$RXRESUME_API_KEY` | his CV variants (career repo) |
| Alfie | `$RXRESUME_ALFIE_API_KEY` | her CVs, one copy per application (tag `candidature`), her cover letters, her application tracker |

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
rxr nico GET /../health | jq -r '.version // "5 (no version field)"'           # 6.x = v6
```

`--retry` is only safe because the default calls above are reads; for a POST, drop it
(`rxr … POST …` then check before retrying — a re-POST duplicates).

## Version differences

| | v5 | v6 |
|---|---|---|
| `GET /api/health` | no `version` | `"version": "6.1.0"` |
| Ended application | `status: rejected` (+ `archived: true` to hide it) | `status: closed` + `closedReason`; `rejected` → 400, `archived` ignored |
| Cover letter | a `cover-letter` section inside the résumé | its own document under `/cover-letters` |
| Résumé PDF | `/resumes/<id>/pdf?target=resume` | `/resumes/<id>/exports/pdf` (`/pdf` still works) |
| Letter PDF | `/resumes/<id>/pdf?target=cover-letter` | `/cover-letters/<letterId>/exports/pdf` (`target=cover-letter` → 400) |
| `DELETE /resumes/<id>` | deletes | moves to Trash (30 days) |
| MCP | — | `POST http://rxresume.home.arpa:13336/mcp`, `x-api-key` |

## Recipes

```bash
# Applications (v6 lists closed ones too; filter with ?status=closed etc.)
rxr alfie GET /applications | jq -r '.[] | "\(.status)\t\(.closedReason // "")\t\(.company)\t\(.role)"'
rxr alfie POST /applications '{"company":"Greenly","role":"Climate Strategy Expert","status":"applied","sourceUrl":"https://…","notes":"…"}'
rxr alfie PUT  /applications/<id> '{"status":"interview"}'
rxr alfie PUT  /applications/<id> '{"status":"rejected"}'                                # v5
rxr alfie PUT  /applications/<id> '{"status":"closed","closedReason":"not-selected"}'    # v6

# Résumé PDF
rxr alfie GET "/resumes/<id>/pdf?target=resume" -o cv.pdf     # v5
rxr alfie GET /resumes/<id>/exports/pdf -o cv.pdf             # v6

# Cover letter PDF
rxr alfie GET "/resumes/<id>/pdf?target=cover-letter" -o lettre.pdf                      # v5
lid=$(rxr alfie GET "/cover-letters?resumeId=<id>" | jq -r '.items | max_by(.updatedAt) | .id')   # v6
rxr alfie GET "/cover-letters/$lid/exports/pdf" -o lettre.pdf                            # v6

rxr nico  GET /resumes/<id> | jq '.data.basics'
```

Statuses: `saved`, `applied`, `screening`, `interview`, `offer`, then the end state: v5
`rejected`; v6 `closed` with `closedReason` ∈ `not-selected` (rejected), `withdrew`,
`accepted-other`, `no-response` (ghosted), `accepted`. Moving a closed card back to an open
stage clears the reason. Check the response.
Before creating an application, list them and match on `sourceUrl`, then company + role:
Alfie may already have added it herself in the web UI (on v6 the match may be a closed card:
reopen it rather than duplicate).

v6 letters: `GET /cover-letters?resumeId=…|applicationId=…` returns `{items,total}` (20 per
page by default, `limit` ≤ 100). Editing one (`PUT /cover-letters/<id>`) needs the letter's
current `revision` as `expectedRevision`. An application links its letter with `coverLetterId`.

## MCP (v6 only)

Stateless streamable HTTP, `POST` only, same key and vault entry:

```bash
( set -a; . "${AGENT_VAULT_ENV:-/var/lib/agent-vault-hermes/proxy.env}"; set +a
  curl -sS -X POST http://rxresume.home.arpa:13336/mcp -H "x-api-key: $RXRESUME_ALFIE_API_KEY" \
    -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools[].name' )
```

If it answers "not initialized", send an `initialize` request first
(`{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hermes","version":"1"}}}`).
The REST recipes above stay the reference; use the MCP when a tool fits better.

## Rules

- **Alfie's data changes only when she asks** (Telegram), never on Nico's say-so alone for
  her CV content. Her CVs and cover letters are produced by the candidatures pipeline on
  Nico's Mac (job-scout: one-page, her template, language of the offer); don't regenerate
  them here, only read, export or track.
- **Nico's CVs**: résumés tagged `claude` are locked and generated from the career repo;
  untagged ones are his own. Never edit either through the API.
- PDF export is rate-limited: on HTTP 429 the body's `reset` (ms) says when.
- Keys: the two existing keys keep full access on v6. A key created on v6 is read-only
  unless "full access" is picked; replacing an application's attached PDF needs `api:delete`.
- The backend is socket-activated and sleeps after 10 idle minutes: the first call can take
  ~20 s or answer 502/503; the retries above cover it.
- Web UI for humans: `https://rpi5.gate-mintaka.ts.net/rxresume` (tailnet only). Password
  reset emails are not sent (no SMTP): a reset needs a DB-side token.
