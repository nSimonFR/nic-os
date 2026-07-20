---
name: dawarich
description: Recap yesterday's location history and fix the timeline in Dawarich — summarize where you went, and confirm/rename/merge/decline the auto-suggested visits. Use for a daily location recap, "where did I go yesterday", or reviewing/cleaning up Dawarich visits.
homepage: https://dawarich.app
metadata: {"openclaw":{"emoji":"🗺️","requires":{"env":["DAWARICH_API_KEY"],"bins":["curl","jq"]},"primaryEnv":"DAWARICH_API_KEY"}}
---

# Dawarich Skill

Use this skill for the user's **Dawarich** self-hosted location history (a Google
Timeline alternative): a recap of a past day, and the daily job of turning Dawarich's
auto-suggested **visits** into a clean timeline (confirm / rename / merge / decline).

Dawarich runs a nightly Sidekiq job (Geoapify-backed) that detects stops and creates
**visits** with `status = "suggested"`. Your job here is to summarize the day and help
the user confirm the good ones, rename the mislabelled ones, merge duplicates, and
decline the noise.

## Setup

On this host (rpi5) the Dawarich API listens on **`http://127.0.0.1:13900`** (loopback)
— NOT `:3900` (that's the Tailscale Serve HTTPS port). `DAWARICH_API_KEY` is already
injected into picoclaw's environment from `/run/agenix/picoclaw-env`, so you do **not**
need to set it yourself — just use `$DAWARICH_API_KEY`.

```bash
export DAWARICH_BASE_URL="${DAWARICH_BASE_URL:-http://127.0.0.1:13900}"
AUTH=(-H "Authorization: Bearer $DAWARICH_API_KEY")
```

Reuse `"${AUTH[@]}"` in every request below.

> **Exec-guard note:** picoclaw's exec safety guard blocks any `$(...)` command
> substitution, so never inline `$(date …)` or `KEY=$(cat …)`. When you need a date,
> run `date -I -d yesterday` (and `date -I`) as their **own** commands first, read the
> printed value, then paste the literal date (e.g. `2026-07-19`) into the URL. Env-var
> expansion like `$DAWARICH_API_KEY` and array use like `"${AUTH[@]}"` are fine — those
> are not command substitution.

## Quick connectivity check

```bash
curl -fsS "$DAWARICH_BASE_URL/api/v1/health"        # {"status":"ok"} — no auth
curl -fsS "${AUTH[@]}" "$DAWARICH_BASE_URL/api/v1/stats" | jq '{km:.totalDistanceKm, cities:.totalCitiesVisited}'
```

If the second call 401s, the key is wrong; if it connection-refuses, the service is down.

---

## Part 1 — Daily recap

Compute the target day first (default: yesterday). Run these as separate commands and
substitute the literal dates:

```bash
date -I -d yesterday      # -> e.g. 2026-07-19   (call this DAY)
```

Cities & countries touched on DAY:

```bash
curl -fsS "${AUTH[@]}" \
  "$DAWARICH_BASE_URL/api/v1/countries/visited_cities?start_at=2026-07-19T00:00:00&end_at=2026-07-19T23:59:59" | jq .
```

Points logged on DAY (activity / whether the phone was tracking):

```bash
curl -fsS "${AUTH[@]}" \
  "$DAWARICH_BASE_URL/api/v1/points?start_at=2026-07-19T00:00:00&end_at=2026-07-19T23:59:59&per_page=1000" \
  | jq 'length'
```

Visits (stops) on DAY — the backbone of the recap, with place, duration and status:

```bash
curl -fsS "${AUTH[@]}" \
  "$DAWARICH_BASE_URL/api/v1/visits?start_at=2026-07-19T00:00:00&end_at=2026-07-19T23:59:59" \
  | jq -r 'sort_by(.started_at)[] | "\(.started_at[11:16])-\(.ended_at[11:16]) | \(.name) | \(.duration)min | \(.status)"'
```

Build a compact, Telegram-friendly recap from those: cities/countries, whether tracking
looked healthy (point count), and the ordered list of stops with names and durations.

Lifetime / long-range stats (for context, not per-day): `GET /api/v1/stats` returns
`totalDistanceKm`, `totalCitiesVisited`, and `yearlyStats[].monthlyDistanceKm` — Dawarich
has no clean per-day km endpoint, so lead the recap with places + cities, not distance.

---

## Part 2 — Fix the timeline (visits)

Visit object shape (from the list endpoint):

```
{ id, started_at, ended_at, duration(min), name, status, confidence,
  place: { id, latitude, longitude }, area_id }
```

`status` is one of: **`suggested`** (needs review), **`confirmed`** (kept), **`declined`** (rejected).

### List the visits that still need review

The list endpoint has **no** status query param — filter client-side with jq:

```bash
curl -fsS "${AUTH[@]}" \
  "$DAWARICH_BASE_URL/api/v1/visits?start_at=2026-07-19T00:00:00&end_at=2026-07-19T23:59:59" \
  | jq -r '[.[] | select(.status=="suggested")]
           | to_entries[]
           | "\(.key+1). id=\(.value.id) | \(.value.name) | \(.value.started_at[11:16])-\(.value.ended_at[11:16]) | \(.value.duration)min"'
```

Present these as a numbered list to the user and ask what to do with each (confirm as-is,
rename, merge, or decline).

### Name suggestions for a visit

If a suggested visit is unnamed or wrong, ask Dawarich for candidate places (nearby POIs
from reverse-geocoding), then offer them:

```bash
curl -fsS "${AUTH[@]}" "$DAWARICH_BASE_URL/api/v1/visits/218/possible_places" | jq .
```

### Confirm / rename a single visit — `PATCH /api/v1/visits/{id}`

Body accepts `name`, `status`, and `place_id` (attach one of the possible_places).

```bash
# confirm as-is
curl -fsS -X PATCH "${AUTH[@]}" -H "Content-Type: application/json" \
  "$DAWARICH_BASE_URL/api/v1/visits/218" -d '{"status":"confirmed"}' | jq '{id,name,status}'

# rename + confirm
curl -fsS -X PATCH "${AUTH[@]}" -H "Content-Type: application/json" \
  "$DAWARICH_BASE_URL/api/v1/visits/218" -d '{"name":"Gym","status":"confirmed"}' | jq '{id,name,status}'

# attach a specific place from possible_places, and confirm
curl -fsS -X PATCH "${AUTH[@]}" -H "Content-Type: application/json" \
  "$DAWARICH_BASE_URL/api/v1/visits/218" -d '{"place_id":3,"status":"confirmed"}' | jq '{id,name,status}'
```

### Decline noise

```bash
curl -fsS -X PATCH "${AUTH[@]}" -H "Content-Type: application/json" \
  "$DAWARICH_BASE_URL/api/v1/visits/218" -d '{"status":"declined"}' | jq '{id,status}'
```

### Bulk confirm / decline — `POST /api/v1/visits/bulk_update`

Body: `visit_ids` (array) + `status` (`suggested`|`confirmed`|`declined`), both required.

```bash
curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
  "$DAWARICH_BASE_URL/api/v1/visits/bulk_update" \
  -d '{"visit_ids":[218,219,221],"status":"confirmed"}' | jq .
```

### Merge duplicate/split visits — `POST /api/v1/visits/merge`

When one real stop got split into several suggestions, merge them into one. Body:
`visit_ids` (array, required).

```bash
curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
  "$DAWARICH_BASE_URL/api/v1/visits/merge" -d '{"visit_ids":[220,221]}' | jq .
```

---

## The morning "recap + fix" loop

This is the intended daily flow (also driven by a cron job):

1. Compute DAY = yesterday.
2. Post a short recap (Part 1): cities, tracking health, and the ordered list of stops.
3. List the **suggested** visits for DAY as a numbered list with `id`, name, time, duration.
4. Ask the user to reply with decisions, e.g. `1=Gym, 2=confirm, 3=merge 4, 5=decline`.
5. Apply each decision with PATCH / bulk_update / merge above, then confirm what changed.

Never mutate a visit without an explicit user decision — the recap and the suggestion list
are read-only; PATCH/merge/bulk_update only run in response to the user's reply.

## Notes / gotchas

- **Timezone:** Dawarich stores `started_at`/`ended_at` with an offset (`+02:00` in
  `Europe/Paris`). The `[11:16]` slice above shows local wall-clock time.
- **Empty day:** if the visits list is `[]`, either nothing was tracked (check the point
  count) or the nightly suggestion job hasn't run yet — say so rather than inventing stops.
- **Scope by date always** (`start_at`/`end_at`); the visits list is otherwise unbounded
  (there are 100+ historical visits).
- Read-only endpoints also useful: `GET /api/v1/areas` (named home/work areas),
  `GET /api/v1/points` (raw GPS).
