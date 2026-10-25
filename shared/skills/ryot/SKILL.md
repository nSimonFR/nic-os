---
name: ryot
description: Log workouts, wishlist media, and query the self-hosted Ryot tracker (V2 REST API + RyotQL) with an API key. Use when the user wants to record a gym session/workout, add a book/film/game/show to their wishlist, log a body measurement, or look up what they've tracked in Ryot.
metadata:
  short-description: Ryot V2 media + fitness tracker via REST/RyotQL + $RYOT_API_KEY
---

# Ryot

[Ryot](https://github.com/IgnisDa/ryot) is the user's self-hosted media & fitness
tracker, running on the rpi5. This is **Ryot V2** (the TypeScript rewrite): there is
no GraphQL any more. Writes go through REST endpoints and plugin operations; every
read is a **RyotQL** document. The headline use is **logging a workout** from a chat
message, plus wishlisting media and querying tracked data.

## How auth works here

All calls go to `http://ryot.home.arpa:13350/api/…` through Agent Vault (an alias for
127.0.0.1; rpi5 only). Auth is the `X-Api-Key` header, but agents hold only the
placeholder `__ryot_api_key__`: Agent Vault swaps in the real key on the way. Source
its proxy env in the same command as the call (it sets the proxy and `$RYOT_API_KEY`).
Humans use the web UI at `https://rpi5.gate-mintaka.ts.net:3710` (tailnet only).

Paste these helpers into the same command as each recipe:

```bash
ryot() {  # ryot <path under /api> [json body] [extra curl args, e.g. -X DELETE]
  ( set -a; . /var/lib/agent-vault-hermes/proxy.env; set +a
    curl -sS --fail-with-body -m 90 "http://ryot.home.arpa:13350/api$1" \
      -H 'Content-Type: application/json' -H "X-Api-Key: $RYOT_API_KEY" \
      ${2:+-d "$2"} "${@:3}" )
}
ryot_ql() {  # ryot_ql '<jq expr yielding {queries:{…}}>' [jq --arg …]
  local e=$1; shift
  ryot /ryotql/execute "$(jq -nc "$@" '
    def col($a; $f): {type:"column", tableAlias:$a, field:$f};
    def lit($v): {type:"literal", value:$v};
    def prop($a; $k): {type:"jsonPath", expr:col($a; "properties"), path:[$k]};
    def cmp($op; $l; $r): {type:"comparison", operator:$op, left:$l, right:$r};
    def is($a; $f; $v): cmp("eq"; col($a; $f); lit($v));
    def like($a; $f; $s): {type:"contains", left:col($a; $f), right:lit($s)};
    def both($ps): {type:"and", predicates:$ps};
    def on_id($t; $a; $l): {type:"inner", table:{table:$t, alias:$a}, on:cmp("eq"; $l; col($a; "id"))};
    def f($k; $e): {key:$k, expr:$e};
    def asc($e): {direction:"asc", expr:$e};
    def desc($e): {direction:"desc", expr:$e};
    def num($e): {type:"cast", target:"number", expr:$e};
    def rows($t; $a; $w; $fs; $o; $n): {from:{table:$t, alias:$a}, where:$w,
      output:{type:"rows", fields:$fs, orderBy:$o, pagination:{limit:$n}}};
    '"$e")"
}
uid() { cat /proc/sys/kernel/random/uuid; }   # fresh submissionId per write

# Sanity check — should print your collections (Watchlist, In Progress, …)
ryot_ql '{queries:{c: rows("entity"; "c"; is("c"; "entitySchemaSlug"; "collection");
  [f("id"; col("c"; "id")), f("name"; col("c"; "name"))]; []; 50)}}' | jq -c '.data.c.items'
```

RyotQL tables used below: `entity` (media items, exercises, workouts, collections —
told apart by `entitySchemaSlug`), `event` (sets, lifecycle, readings — by
`eventSchemaSlug`) and `relationship` (collection membership = `member-of`). A
response is `{data:{<name>:{items, pageInfo:{hasMore, nextCursor}}}}`; at most 100
rows per query, 10 queries per document.

Plugin operations (`POST /plugins/ryot/<fitness|media>/operations/<slug>`) answer
**HTTP 200 even when they refuse**: always check `.result.kind` / `.result.status`.
Writes carry `submissionId` (unique per write; reusing one replays the old result)
and `submittedAt` (now, ISO-8601).

## Register a workout  ⭐ (the main use case)

### 1. Read a similar prior workout first — mandatory

**Before every create or correction**, list recent workouts and read at least one
similar workout in full. Reuse its exact `exerciseId`, exercise order, and set-type
convention whenever the same movement appears. **The current workout always overrides
historical set count, reps, weight, and exercise order:** write exactly what the user
reported for this session. This prevents accidental substitution of a Smith-machine,
cable, or free-weight exercise for a standalone machine. If no comparable entry exists,
search the library and explicitly verify the chosen exercise's `id`, `name`, and `kind`
before writing.

```bash
# 1) Recent workouts, newest first; choose the closest match.
ryot_ql '{queries:{w: rows("entity"; "w"; is("w"; "entitySchemaSlug"; "workout");
  [f("id"; col("w"; "id")), f("name"; col("w"; "name")), f("startedAt"; prop("w"; "startedAt"))];
  [desc({type:"cast", target:"date", expr:prop("w"; "startedAt")})]; 10)}}' | jq -c '.data.w.items[]'

# 2) Its sets in order (exerciseId, setLot, reps/weight/duration/distance, PB flags).
ryot_ql '{queries:{s: rows("event"; "s";
  both([is("s"; "sessionEntityId"; $w), is("s"; "eventSchemaSlug"; "workout-set")]);
  [f("exerciseId"; col("s"; "entityId")), f("set"; col("s"; "properties")),
   f("pbs"; {type:"jsonPath", expr:col("s"; "projection"), path:["personalBests"]})];
  [asc(num(prop("s"; "exerciseOrder"))), asc(num(prop("s"; "setOrder")))]; 100)}}' \
  --arg w 'wor_…' | jq -c '.data.s.items[]'
```

Do this read **immediately before** the write, not merely earlier in the session.

### 2. Resolve the exercise id

Library exercises keep their V1 ids, which are their **exact human names** (e.g.
`"Barbell Bench Press - Medium Grip"`); custom ones are `ent_…`. V2 **rejects** an
unknown id (`{"kind":"invalid","code":"missing-exercise"}`), so never guess a plain
name like `"Barbell Bench Press"` — it does not exist.

```bash
# Exercises the user has already logged, most recent first (prefer these)
ryot_ql '{queries:{u: (rows("event"; "s";
    both([is("s"; "eventSchemaSlug"; "workout-set"), like("e"; "name"; $q)]); []; []; 1)
  | .joins = [on_id("entity"; "e"; col("s"; "entityId"))]
  | .output = {type:"aggregate", limit:20,
      groupBy:[f("exerciseId"; col("e"; "id")), f("kind"; prop("e"; "kind"))],
      measures:[{key:"sets", aggregation:{function:"count"}},
                {key:"last", aggregation:{function:"maximum", expr:col("s"; "occurredAt")}}],
      orderBy:[{key:"last", direction:"desc"}]})}}' --arg q 'bench press' | jq -c '.data.u.items[]'

# Whole library (873 exercises), case-insensitive substring
ryot_ql '{queries:{x: rows("entity"; "e";
  both([is("e"; "entitySchemaSlug"; "exercise"), like("e"; "name"; $q)]);
  [f("id"; col("e"; "id")), f("name"; col("e"; "name")), f("kind"; prop("e"; "kind"))]; []; 50)}}' \
  --arg q 'bench press' | jq -c '.data.x.items[]'
```

The exercise's `kind` decides which `measurements` a set needs (all required):

| kind | measurements |
|---|---|
| `reps_and_weight` | `reps`, `weight` (kg) |
| `reps` | `reps` |
| `duration` | `duration` (**seconds**) |
| `distance_and_duration` | `distance` (km), `duration` (s) |
| `reps_and_duration` | `reps`, `duration` (s) |
| `reps_and_duration_and_distance` | `reps`, `duration` (s), `distance` (km) |

Send only the fields of that kind; an extra or missing one → `invalid-exercise-kind`
/ `missing-measurement`.

### 3. Build and send the workout

Operation **`workout-editor-save`**. Each `occurrences[]` entry is one exercise
placement with its `sets`; every set needs `clientId`, `occurredAt`, `confirmedAt`
(unconfirmed sets are refused), `setLot`, `exerciseKind` (= the exercise's `kind`) and
`measurements` as **numbers**. `clientId`s are any unique strings.

```bash
# "Bench this morning: warm-up 10x40, then 10@60, 8@70, 6@75 to failure, ~35 min"
P=$(jq -nc --arg id "$(uid)" --arg now "$(date -u +%FT%TZ)" '{payload:{
  submissionId:$id, submittedAt:$now, data:{
    kind:"workout", name:"Morning session", target:{kind:"create"},
    startedAt:"2026-07-23T08:00:00Z", endedAt:"2026-07-23T08:35:00Z",
    activeDuration:{kind:"set", seconds:2100},
    images:[], videos:[], supersets:[],
    occurrences:[{clientId:"o1", exerciseId:"Barbell Bench Press - Medium Grip",
      images:[], videos:[], notes:[],
      sets:([[10,40,"warm_up"],[10,60,"normal"],[8,70,"normal"],[6,75,"failure"]]
        | to_entries | map({clientId:"s\(.key)", occurredAt:"2026-07-23T08:05:00Z",
            confirmedAt:"2026-07-23T08:05:00Z", setLot:.value[2],
            exerciseKind:"reps_and_weight", measurements:{reps:.value[0], weight:.value[1]}}))}]}}}')
ryot /plugins/ryot/fitness/operations/workout-editor-save "$P" | jq -c .result
# → {"kind":"saved","entityId":"ent_…","sets":[…]}  (anything else = not saved)
```

Notes:
- **Current-workout precedence.** The user's stated set count, reps, weight, and
  exercise order are authoritative and must be written exactly; never add, remove, or
  normalize sets from prior history. Reuse historical data only for the verified
  `exerciseId` and, unless the user specifies otherwise, the `setLot` pattern. Do not
  substitute a different equipment variant.
- **`setLot`**: `normal` | `warm_up` | `drop` | `failure`. Default to `normal` only
  when the user did not specify a set type and no comparable set convention exists.
- Optional per set: `rpe` (int 0–10), `restTime` (int seconds). Optional per
  occurrence: `notes` (array of strings). Optional per workout: `comment`,
  `caloriesBurnt` (kcal number). `activeDuration` may be `{kind:"clear"}` when unknown.
- **Per-set `note` is a Pro feature** → `{"kind":"pro-required"}`; put the text in the
  occurrence `notes` or the workout `comment` instead.
- Bodyweight movements have kind `reps`: send `{reps:…}` only.
- Prefer real timestamps. If the user says "this morning / just now", use the current
  time for `endedAt` and back-date `startedAt` by the session length.
- **Correcting** a saved workout: delete it and save the corrected one (an in-place
  update needs the web editor's conflict token). Keep name/times unless corrected.

```bash
# Delete (accidental/test entry, or before re-saving a correction)
ryot /plugins/ryot/fitness/operations/workout-delete \
  "$(jq -nc --arg id "$(uid)" --arg now "$(date -u +%FT%TZ)" --arg w 'ent_…' \
     '{payload:{submissionId:$id, submittedAt:$now, entityId:$w}}')" | jq -c .result
```

### Personal bests: verify, then congratulate

After saving, read the workout back (step 1, query 2). Ryot computes PBs itself,
against **earlier** sessions only: each set's `pbs` lists the records it set
(`weight`, `reps`, `one_rm`, `volume`, `time`, `pace`, `distance`). Confirm against
the history of the same exercise, excluding this workout:

```bash
ryot_ql '{queries:{h: rows("event"; "s";
  both([is("s"; "entityId"; $x), is("s"; "eventSchemaSlug"; "workout-set"),
        cmp("neq"; col("s"; "sessionEntityId"); lit($w))]);
  [f("at"; col("s"; "occurredAt")), f("set"; col("s"; "properties")),
   f("oneRm"; {type:"jsonPath", expr:col("s"; "projection"), path:["oneRm"]})];
  [desc(col("s"; "occurredAt"))]; 100)}}' \
  --arg x 'Barbell Bench Press - Medium Grip' --arg w 'ent_…' | jq -c '.data.h.items[]'
```

If a PB is confirmed, include a short, enthusiastic congratulations in French with
the exercise and the actual improvement (previous → new). An empty history means the
`pbs` flags mark a **first performance — a baseline, not a record**. Distinguish a
record within the retrieved history from an all-time record when history is
incomplete. Never invent a record, treat different machine variants as comparable,
or claim an estimated 1RM (`oneRm`) is a measured maximum. If no PB is verified,
simply confirm the session.

## Wishlist media

The wishlist is the **`Watchlist`** collection (every media type). Migrated wishlist
items also carry a `backlog` status, which is what V2's media pages show as "want
to"; set both. Flow: find the item's entity id → add to Watchlist → log backlog.

```bash
# 1a. Already known locally? (entitySchemaSlug: book, movie, show, video-game, anime, …)
ryot_ql '{queries:{m: rows("entity"; "e";
  both([is("e"; "entitySchemaSlug"; $t), like("e"; "name"; $q)]);
  [f("id"; col("e"; "id")), f("name"; col("e"; "name")), f("year"; prop("e"; "publishYear"))]; []; 20)}}' \
  --arg t movie --arg q 'peanut butter' | jq -c '.data.m.items[]'

# 1b. Otherwise search a provider. Provider ids differ per install: resolve by slug.
PROV=$(ryot_ql '{queries:{p: rows("sandboxProvider"; "p"; is("p"; "slug"; $s);
  [f("id"; col("p"; "id"))]; []; 1)}}' --arg s book.openlibrary | jq -r '.data.p.items[0].id')
ryot /entity-providers/search "$(jq -nc --arg p "$PROV" --arg q 'Dune Frank Herbert' \
  '{providerId:$p, query:$q, page:1, pageSize:5}')" | jq -c '.items[]'   # {title, externalId, metadata:[year]}

# 1c. Import the chosen result → entity id (a job; re-poll while queued/running)
JOB=$(ryot /entity-providers/imports "$(jq -nc --arg p "$PROV" --arg x 'OL893414W' \
  '{providerId:$p, externalId:$x}')" | jq -r .jobId)
ryot "/entity-providers/imports/$JOB" | jq -c '{status, id:.data.id, name:.data.name}'

# 2. Add to Watchlist (collection id from the sanity check; Watchlist = col_nQTcy0g95IGi at migration)
ryot /collections/memberships '{"entityId":"ent_…","collectionId":"col_…"}' | jq -c .memberOf.id

# 3. Mark it backlog
ryot /plugins/ryot/media/operations/media-activity-log "$(jq -nc --arg id "$(uid)" \
  --arg now "$(date -u +%FT%TZ)" --arg e 'ent_…' \
  '{payload:{submissionId:$id, submittedAt:$now, entry:{kind:"status", status:"backlog", entityId:$e}}}')" \
  | jq -c .result   # → {"count":1,"status":"saved"}

# Remove from Watchlist (same body, DELETE)
ryot /collections/memberships '{"entityId":"ent_…","collectionId":"col_…"}' -X DELETE
```

Provider slugs: `book.openlibrary` / `book.google-books` / `book.hardcover`,
`movie.tmdb`, `show.tmdb`, `video-game.igdb`, `anime.anilist` / `anime.myanimelist`,
`manga.anilist`, `music.spotify`, `podcast.itunes` / `podcast.listennotes`,
`audiobook.audible`, `visual-novel.vndb`, `comic-book.metron` (list all:
`rows("sandboxProvider"; …)` with field `slug`). The first poll usually already says
`completed`; `failed` means a bad `externalId`.

To undo everything a test wishlist did to an item (events + memberships):
`ryot "/entity-user-data/clear/ent_…" '' -X DELETE`.

## Query tracked data

```bash
# What's on a collection, newest first (swap "Watchlist" for any collection name)
ryot_ql '{queries:{i: (rows("relationship"; "m";
    both([is("m"; "relationshipSchemaSlug"; "member-of"), is("c"; "name"; $c)]);
    [f("id"; col("e"; "id")), f("name"; col("e"; "name")), f("type"; col("e"; "entitySchemaSlug")),
     f("addedAt"; col("m"; "createdAt"))]; [desc(col("m"; "createdAt"))]; 100)
  | .joins = [on_id("entity"; "e"; col("m"; "sourceEntityId")),
              on_id("entity"; "c"; col("m"; "targetEntityId"))])}}' \
  --arg c Watchlist | jq -c '.data.i.items[]'

# One item: which collections, and its history (backlog/progress/complete/dropped/on_hold/review)
ryot_ql '{queries:{
  cols: (rows("relationship"; "m"; both([is("m"; "sourceEntityId"; $e), is("m"; "relationshipSchemaSlug"; "member-of")]);
    [f("collection"; col("c"; "name"))]; []; 20) | .joins = [on_id("entity"; "c"; col("m"; "targetEntityId"))]),
  events: rows("event"; "ev"; is("ev"; "entityId"; $e);
    [f("id"; col("ev"; "id")), f("kind"; col("ev"; "eventSchemaSlug")), f("at"; col("ev"; "occurredAt")),
     f("properties"; col("ev"; "properties"))]; [desc(col("ev"; "occurredAt"))]; 50)}}' \
  --arg e 'met_…' | jq -c '.data'

# Recent media activity (add both([…, is("e"; "entitySchemaSlug"; "show")]) to filter a type)
ryot_ql '{queries:{r: (rows("event"; "ev";
    {type:"in", expr:col("ev"; "eventSchemaSlug"), values:[lit("complete"), lit("progress")]};
    [f("at"; col("ev"; "occurredAt")), f("what"; col("ev"; "eventSchemaSlug")),
     f("type"; col("e"; "entitySchemaSlug")), f("name"; col("e"; "name"))];
    [desc(col("ev"; "occurredAt"))]; 20)
  | .joins = [on_id("entity"; "e"; col("ev"; "entityId"))])}}' | jq -c '.data.r.items[]'

# Body measurements: latest readings (metric name + value), newest first
ryot_ql '{queries:{r: (rows("event"; "r"; is("r"; "eventSchemaSlug"; "measurement-reading");
    [f("at"; col("r"; "occurredAt")), f("metric"; col("m"; "name")), f("value"; prop("r"; "value"))];
    [desc(col("r"; "occurredAt"))]; 20)
  | .joins = [on_id("entity"; "m"; col("r"; "entityId"))])}}' | jq -c '.data.r.items[]'
```

Default collections: **Watchlist** (wishlist), **In Progress**, **Completed**,
**Owned**, **Reminders**, **Monitoring**, **Custom**.

### Bonus: log a body measurement

Metrics are `measurement-metric` entities (`Weight`, `Body Fat`, `Bmi`, `Muscle
Mass`, …; ids per install). A Loftilla scale already auto-logs weigh-ins
(`project_scale_bridge`), so only add manual entries on request.

```bash
# Metric ids
ryot_ql '{queries:{m: rows("entity"; "m"; is("m"; "entitySchemaSlug"; "measurement-metric");
  [f("id"; col("m"; "id")), f("name"; col("m"; "name"))]; []; 50)}}' | jq -c '.data.m.items[]'

ryot /plugins/ryot/fitness/operations/measurement-reading-log "$(jq -nc --arg id "$(uid)" \
  --arg now "$(date -u +%FT%TZ)" --arg m '<weight metric id>' '{payload:{submissionId:$id,
  submittedAt:$now, occurredAt:"2026-07-23T08:00:00Z", values:[{metricId:$m, value:82.5}]}}')" \
  | jq -c .result   # → {"count":1,"status":"saved"}
```

Undo: the reading's `sessionEntityId` (select `col("r"; "sessionEntityId")` in the
readings query) is the entry id →
`ryot /plugins/ryot/fitness/operations/measurement-reading-delete '{"payload":{"entryId":"ent_…"}}'`.

## Troubleshooting

- **HTTP 400 from `/ryotql/execute`**: the body names the bad field/alias. Fields per
  table: select `{type:"wildcard", tableAlias:"x"}` instead of `f(…)` to see them all.
- **Operation returned 200 but nothing changed**: read `.result` — `invalid` (+`code`),
  `pro-required`, or `conflict`.
- **`missing-config` from a provider search** (`TMDB access token`, `Twitch client
  ID`): the provider key is not configured in `ryot.nix`; tell the user.
- **401**: run through `ryot` (it sources the proxy env). Still 401 → the key in
  `agent-brokered-env` is revoked. A new key is minted from a signed-in session with
  `POST /api/auth/api-key/create {"name":"agents"}`, and stored as `RYOT_API_KEY` in
  `hosts/rpi5/secrets/agent-brokered-env.age`. Ask the user before rotating.
- API reference (every route, request schema): `http://127.0.0.1:13350/api/docs`.
