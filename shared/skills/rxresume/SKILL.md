---
name: rxresume
description: Read and update CVs, cover letters and job-application tracking in the self-hosted Reactive Resume v6 (REST API or its built-in MCP server) — Nico's account or Alfie's. Use when asked to list or export a CV/letter as PDF, look up or change the status of a job application (applied, interview, closed…), record a new application, or attach documents to it.
metadata:
  short-description: Reactive Resume v6 REST + MCP (CVs, letters, application tracker) for Nico and Alfie
---

# Reactive Resume (v6)

Self-hosted Reactive Resume **v6.1** on rpi5 (UI: `https://rpi5.gate-mintaka.ts.net/rxresume`, tailnet only).
Two accounts, two keys, both brokered by Agent Vault (agents only hold placeholders):

| Whose | Key variable | What lives there |
|---|---|---|
| Nico | `$RXRESUME_API_KEY` | his CV variants (career repo) |
| Alfie | `$RXRESUME_ALFIE_API_KEY` | her CVs, one copy per application (tag `candidature`), letters, her tracker |

Pick the account from who the request is about. Never cross them.

```bash
rxr() {  # rxr <nico|alfie> <METHOD> <path under /api/openapi> [json body] [extra curl args]
  ( set -a; . "${AGENT_VAULT_ENV:-/var/lib/agent-vault-hermes/proxy.env}"; set +a
    k=$RXRESUME_API_KEY; [ "$1" = alfie ] && k=$RXRESUME_ALFIE_API_KEY
    curl -sS --fail-with-body -m 300 -X "$2" "http://rxresume.home.arpa:13336/api/openapi$3" \
      -H "x-api-key: $k" ${4:+-H 'Content-Type: application/json' -d "$4"} "${@:5}" )
}
rxr alfie GET /resumes | jq -r '.[] | "\(.updatedAt[:10])  \(.name)  \(.tags)"'   # sanity check
```

The backend is socket-activated (first call after 10 idle minutes can take ~20 s or 502: retry a GET,
never blindly re-POST — a re-POST duplicates).

## Recipes

```bash
rxr alfie GET /applications | jq -r '.[] | "\(.status)\(.closedReason // "" | if . != "" then ":"+. else "" end)\t\(.company)\t\(.role)"'
rxr alfie POST /applications '{"company":"Greenly","role":"Climate Strategy Expert","status":"applied","sourceUrl":"https://…"}'
rxr alfie PUT  /applications/<id> '{"status":"interview"}'
rxr alfie PUT  /applications/<id> '{"status":"closed","closedReason":"not-selected"}'
rxr alfie GET  "/resumes/<id>/exports/pdf" -o cv.pdf
rxr alfie GET  "/cover-letters?resumeId=<id>" | jq '.items[] | {id, name, revision}'   # wrapped in .items
rxr alfie GET  "/cover-letters/<letterId>/exports/pdf" -o lettre.pdf
```

- **Statuses**: `saved`, `applied`, `screening`, `interview`, `offer`, `closed`. A refusal, withdrawal or
  dead end is `closed` + `closedReason` ∈ `not-selected`, `withdrew`, `accepted-other`, `no-response`,
  `accepted`. There is no `rejected` and no `archived` any more (closed applications stay listed).
- **Cover letters are separate documents** (`/cover-letters`), linked to a resume (`resumeId`) and to an
  application (`coverLetterId`). Updates need the current `expectedRevision`.
- **Before creating an application**, list them and match on `sourceUrl`, then company + role: Alfie may
  already have added it herself in the web UI.
- `DELETE /resumes/{id}` moves to Trash. PDF/letter exports are rate-limited: on 429, wait for the window.

## MCP server

Endpoint `http://rxresume.home.arpa:13336/mcp` (streamable HTTP, header `x-api-key`, same keys/vault).
~150 tools, e.g. `list_applications`, `update_application`, `add_application_note`,
`attach_application_document`, `read_resume`, `download_resume_pdf`, `list_cover_letters`,
`export_cover_letter`. Its AI tools (`tailor_resume_for_application`, `score_application_match`,
`autofill_application_from_job`, `draft_application_message`) need an AI provider configured inside
Reactive Resume — not set up here, don't rely on them. Keys created in v6 are read-only unless granted
full access.

## Rules

- **Alfie's data changes only when she asks** (Telegram). Her CVs and letters are produced by the
  candidatures pipeline (one page, her template, the offer's language): read, export or track here, don't
  regenerate them.
- **Nico's CVs**: résumés tagged `claude` are locked and generated from the career repo
  (`scripts/rr.sh`, `scripts/apply.py`); untagged ones are his own. Never edit either through the API.
