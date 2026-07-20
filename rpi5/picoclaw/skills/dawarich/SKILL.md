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
export DAWARICH_BASE_URL="${DAWARICH_BASE_URL:-http://127.0.0.1:13900}"   # API (loopback)
export DAWARICH_WEB_URL="${DAWARICH_WEB_URL:-https://rpi5.gate-mintaka.ts.net:3900}"  # UI (for user-facing links)
AUTH=(-H "Authorization: Bearer $DAWARICH_API_KEY")
```

Reuse `"${AUTH[@]}"` in every request below. `DAWARICH_BASE_URL` is loopback and only
reachable from rpi5 — never put it in a message. Links you send the user must use
`DAWARICH_WEB_URL` (the Tailscale Serve URL, reachable from their phone on the tailnet).

> **Exec-guard note:** picoclaw's exec safety guard blocks any `$(...)` command
> substitution, so never inline `$(date …)` or `KEY=$(cat …)`. When you need a date,
> run `date -I -d yesterday` (and `date -I`) as their **own** commands first, read the
> printed value, then paste the literal date (e.g. `2026-07-19`) into the URL. Env-var
> expansion like `$DAWARICH_API_KEY` and array use like `"${AUTH[@]}"` are fine — those
> are not command substitution.

## Dawarich deep links (for user-facing messages)

The modern UI is `/map/v2` with a timeline panel that takes a date and a status filter.
Build links off `DAWARICH_WEB_URL` so they open the right day straight from Telegram:

- **Full day timeline:** `$DAWARICH_WEB_URL/map/v2?panel=timeline&date=DAY&status=all`
- **Review suggestions (the fix view):** `$DAWARICH_WEB_URL/map/v2?panel=timeline&date=DAY&status=suggested`

`DAY` is `YYYY-MM-DD` (e.g. `2026-07-19`). Always include a link to the suggestions view
in the daily message so the user can also fix the timeline visually in one tap.

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

This is the raw list for your own use — do **not** send it verbatim. Format it for the user
per "Sending the daily message to Telegram" below (one status-annotated list, trimmed names,
no raw `id=`), keeping the sort stable so the reply numbers map back to these ids.

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

## Sending the daily message to Telegram (rich)

When this runs as the daily job (channel `telegram`), send the recap yourself via the
Bot API so you get HTML formatting **and** tap-through buttons — don't rely on picoclaw's
plain-text channel rendering. Token is at `/run/agenix/telegram-bot-token`; the chat id is
in `$TELEGRAM_CHAT_ID` (exported for the service).

Use `parse_mode=HTML`. Make place names and the header clickable, and attach an inline
keyboard of **URL buttons** (deep links from the section above). Build the message body and
`reply_markup` in files (avoids `$(...)`), then POST:

```bash
# ...after writing $work/message.html (HTML) and $work/markup.json ...
TOKEN=$(cat /run/agenix/telegram-bot-token)
curl -fsS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id="$TELEGRAM_CHAT_ID" \
  -d parse_mode=HTML \
  -d link_preview_options='{"is_disabled":true}' \
  --data-urlencode text@"$work/message.html" \
  --data-urlencode reply_markup@"$work/markup.json"
```

Add `--max-time 15` to every `curl` in the send script — the exec tool kills a command
after ~60s, and three API calls + formatting can approach that on a slow day.

`markup.json` — two URL buttons (these work with no bot-side handling; Telegram opens them):

```json
{"inline_keyboard":[[
  {"text":"🗺 Open timeline","url":"https://rpi5.gate-mintaka.ts.net:3900/map/v2?panel=timeline&date=2026-07-19&status=all"},
  {"text":"✅ Review suggestions","url":"https://rpi5.gate-mintaka.ts.net:3900/map/v2?panel=timeline&date=2026-07-19&status=suggested"}
]]}
```

### Layout — ONE status-annotated list (not two)

Do **not** print a separate "Stops" list and "Suggested" list — that repeats every place.
Print **one** list of the day's visits, sorted by start time, each prefixed by its status:

- **`❓ N`** — a `suggested` visit. `N` is a running number (1, 2, 3 … over the suggested
  ones only). This is what the user replies with.
- **`✅`** (no number) — a `confirmed` visit. It needs nothing; show it dimmed so the day
  reads as complete.
- omit `declined` visits.

Formatting rules:
- **Trim the name to its first comma-segment** (the venue): `Restaurant Méert, Rue de
  l'Espérance, 23, Roubaix` → `Restaurant Méert`. Full detail is one tap away via the link.
- **Never show a raw `id=`** — the user replies by number (you map number→id yourself; see
  "Applying replies").
- **Humanize duration:** `230` → `3h50`, `37` → `37min`.
- **Human date** in the header: run `date -d DAY '+%a %-d %b'` as its own command → `Sun 29 Mar`.
- **Flag low tracking:** append `(sparse)` after the point count when it's low (< ~50/day).

HTML body shape:

```
🗺 <b><a href="…date=DAY&status=all">Dawarich · Sun 29 Mar</a></b>
📍 <b>Roubaix, France</b> · 17 pts (sparse)

2 stops to review, 1 already confirmed:

❓ 1  <a href="…date=DAY&status=suggested">Restaurant Méert</a> · 16:21–16:58 · 37min
❓ 2  Le Grand Café · 17:46–18:09 · 23min
✅    Home · 19:20–23:10 · 3h50

Reply per number:  ok (keep) · a name (rename) · no (drop) · "merge 1 2"
```

If nothing needs review, drop the legend and end with `all confirmed ✅`. If the day has no
visits at all, send a one-liner and check the point count (don't invent stops).

> **HTML-escape** names before embedding: `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;` (Dawarich
> names can contain `&`). Only `<b> <i> <a> <code>` tags are allowed. **No action buttons:**
> picoclaw ignores `callback_query`, so the two `url` buttons are the only interactive
> Telegram element — the actual keep/rename/drop/merge happens by text reply.

### Applying replies (a later turn)

The user replies to the recap later, in a fresh turn with no memory of the numbering, e.g.
`1 ok, 2 Le Grand Café, 3 no` or `merge 1 2`. Re-fetch that day's **suggested** visits in the
SAME sort (`started_at`) and number them 1, 2, 3 … to map numbers → visit ids, then apply:

- `ok` / `keep` → `PATCH status=confirmed`
- a free-text name → `PATCH name=… status=confirmed`
- `no` / `drop` → `PATCH status=declined`
- `merge A B` → `POST /visits/merge` with those ids

Default to yesterday (the last recap's day) unless the user names a date. Reply confirming
exactly what changed.

## The morning "recap + fix" loop

This is the intended daily flow (also driven by a cron job):

1. Compute DAY = yesterday.
2. Send ONE rich Telegram message (see "Sending" above): human-date header, place line, and a
   single status-annotated list (❓ numbered = needs review, ✅ = already confirmed), a
   `Reply per number` legend, and the two URL buttons.
3. When the user replies (a later turn), map their numbers → visit ids by re-fetching that
   day's suggested visits in the same order, then apply keep / rename / drop / merge.
4. Reply confirming exactly what changed.

Never mutate a visit without an explicit user decision — the recap is read-only;
PATCH/merge/bulk_update only run in response to the user's reply.

## Notes / gotchas

- **Timezone:** Dawarich stores `started_at`/`ended_at` with an offset (`+02:00` in
  `Europe/Paris`). The `[11:16]` slice above shows local wall-clock time.
- **Empty day:** if the visits list is `[]`, either nothing was tracked (check the point
  count) or the nightly suggestion job hasn't run yet — say so rather than inventing stops.
- **Scope by date always** (`start_at`/`end_at`); the visits list is otherwise unbounded
  (there are 100+ historical visits).
- Read-only endpoints also useful: `GET /api/v1/areas` (named home/work areas),
  `GET /api/v1/points` (raw GPS).
