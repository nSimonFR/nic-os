---
name: ryot
description: Log workouts, wishlist media, and query the self-hosted Ryot tracker via its GraphQL API with a Bearer token. Use when the user wants to record a gym session/workout, add a book/film/game/show to their wishlist, or look up what they've tracked in Ryot.
metadata:
  short-description: Ryot media + fitness tracker via GraphQL + $RYOT_API_KEY
---

# Ryot

[Ryot](https://github.com/IgnisDa/ryot) is the user's self-hosted media & fitness
tracker, running natively on the rpi5. This skill drives it over its GraphQL API —
the headline use is **logging a workout** from a chat message, plus wishlisting
media and querying tracked data.

## How auth works here

All calls go to the **local backend** `http://127.0.0.1:13352/graphql` (this
machine runs Ryot; agents call it on localhost — no HTTPS, no funnel). Auth is a
Bearer token in `$RYOT_API_KEY`.

**Resolve `$RYOT_API_KEY` before giving up.** Interactive `nsimon` shells may not
export it, and systemd-spawned agents (Hermes, `claude-remote-control`) run with a
minimal env. The token lives in the agent creds file `/run/agenix/picoclaw-env`
(owner `nsimon`, mode 400 — readable by the agents, always present). Self-heal at
the start of any Ryot task:

```bash
if [ -z "$RYOT_API_KEY" ] && [ -r /run/agenix/picoclaw-env ]; then
  export RYOT_API_KEY=$(sed -n 's/^RYOT_API_KEY=//p' /run/agenix/picoclaw-env)
fi
```

Only if `$RYOT_API_KEY` is still empty after this, stop and tell the user (a fresh
token can be minted with the `generateAuthToken` mutation using an existing session
— see Troubleshooting).

Helper used throughout — a query/mutation runner that self-heals the key:

```bash
ryot_q() {  # ryot_q '<graphql>' '<variables-json>'
  [ -z "$RYOT_API_KEY" ] && [ -r /run/agenix/picoclaw-env ] && \
    export RYOT_API_KEY=$(sed -n 's/^RYOT_API_KEY=//p' /run/agenix/picoclaw-env)
  curl -fsS http://127.0.0.1:13352/graphql \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $RYOT_API_KEY" \
    -d "$(jq -nc --arg q "$1" --argjson v "${2:-{\}}" '{query:$q, variables:$v}')"
}

# Sanity check — should print your name + lot (ADMIN)
ryot_q 'query{ userDetails{ ... on UserDetails { id name lot } } }' | jq -c '.data.userDetails'
```

The token is user-scoped (identity `nsimon`, id **`usr_o04hupYGQWIM`** — the
`creatorUserId` used for collection ops). The admin token from `ryot-env` is NOT a
substitute: it cannot perform the user-scoped mutations below (workouts,
collections).

## Register a workout  ⭐ (the main use case)

Mutation: **`createOrUpdateUserWorkout(input: UserWorkoutInput!)`** → returns the
new workout id (`wor_…`).

### 1. Resolve the exercise id

**An exercise's id is its human name** (e.g. `"Barbell Bench Press - Medium Grip"`),
and it must match the library **exactly** (case-sensitive). ⚠️ Ryot **silently
accepts an unknown exerciseId** and stores it as a junk/orphan exercise — the create
still returns a `wor_…` id, so you won't see an error. Always **search first** and
use a returned id verbatim; never guess a plain name like `"Barbell Bench Press"`
(that one does NOT exist — the real ids are grip/equipment-qualified):

```bash
# Search returns exercise ids (== names)
ryot_q 'query($q:String!){ userExercisesList(input:{search:{query:$q}}){ response{ items } } }' \
  '{"q":"bench press"}' | jq -c '.data.userExercisesList.response.items'

# What statistic fields does an exercise expect? -> its ExerciseLot (use a real id)
ryot_q 'query($id:String!){ exerciseDetails(exerciseId:$id){ id name lot } }' \
  '{"id":"Barbell Bench Press - Medium Grip"}' | jq -c '.data.exerciseDetails'
```

`ExerciseLot` decides which `statistic` fields to fill:

| ExerciseLot | statistic fields to send |
|---|---|
| `REPS_AND_WEIGHT` | `reps`, `weight` |
| `REPS` | `reps` |
| `DURATION` | `duration` (minutes) |
| `DISTANCE_AND_DURATION` | `distance`, `duration` |
| `REPS_AND_DURATION` | `reps`, `duration` |
| `REPS_AND_DURATION_AND_DISTANCE` | `reps`, `duration`, `distance` |

### 2. Build and send the workout

Required input fields: `name`, `startTime`, `endTime` (RFC3339 / ISO-8601),
`supersets` (send `[]` when none), and `exercises`. Each exercise needs
`exerciseId`, `unitSystem` (`METRIC` → weight in **kg**, distance in km),
`notes` (send `[]`), and `sets`. Each set needs `lot` (`SetLot`) and `statistic`.
Numeric statistic values are `Decimal` → **send them as strings**.

```bash
# Example: "3 sets of bench press — 10@60kg, 8@70kg, 6@75kg — ~35 min this morning"
VARS=$(jq -nc '{input:{
  name:"Morning session",
  startTime:"2026-07-23T08:00:00Z",
  endTime:"2026-07-23T08:35:00Z",
  supersets:[],
  exercises:[{
    exerciseId:"Barbell Bench Press - Medium Grip",   # a REAL id from userExercisesList
    unitSystem:"METRIC",
    notes:[],
    sets:[
      {lot:"WARM_UP", statistic:{reps:"10", weight:"40"}},
      {lot:"NORMAL",  statistic:{reps:"10", weight:"60"}},
      {lot:"NORMAL",  statistic:{reps:"8",  weight:"70"}},
      {lot:"FAILURE", statistic:{reps:"6",  weight:"75"}, rpe:9, restTime:120}
    ]
  }]
}}')
ryot_q 'mutation($input:UserWorkoutInput!){ createOrUpdateUserWorkout(input:$input) }' "$VARS" \
  | jq -r '.data.createOrUpdateUserWorkout // .errors'
```

Notes:
- **`SetLot`**: `NORMAL` | `WARM_UP` | `DROP` | `FAILURE`. Default to `NORMAL`.
- Multiple exercises → add more entries to `exercises[]`. Each carries its own `sets`.
- Optional per-set: `rpe` (Int 1–10), `restTime` (Int seconds), `note` (String).
- Optional workout-level: `duration` (Int seconds — otherwise derived from start/end),
  `comment` (String), `caloriesBurnt` (Decimal-as-string).
- If a set weight is bodyweight-only (e.g. pull-ups), send just `{reps:"…"}`.
- Prefer real timestamps. If the user says "this morning / just now", use the current
  time for `endTime` and back-date `startTime` by the session length.

### Read workouts back

```bash
# Recent workouts (items are wor_… ids)
ryot_q 'query{ userWorkoutsList(input:{}){ response{ items details{ totalItems nextPage } } } }' \
  | jq -c '.data.userWorkoutsList.response'

# Full detail of one workout (wrapped in `response`; exercises live under
# details.information.exercises)
ryot_q 'query($id:String!){ userWorkoutDetails(workoutId:$id){ response{
  details{ name startTime endTime duration
    information{ exercises{ id lot sets{ lot statistic{ reps weight duration distance } } } } } } } }' \
  '{"id":"wor_…"}' | jq -c '.data.userWorkoutDetails.response.details'

# Delete (e.g. an accidental/test entry)
ryot_q 'mutation($id:String!){ deleteUserWorkout(workoutId:$id) }' '{"id":"wor_…"}'
```

## Wishlist media

Ryot's default "wishlist" collection is named **`Watchlist`** (works for every media
type, not just video). Flow: search for the item → get its Ryot `met_…` id → add it
to the collection.

```bash
# 1. Search. lot + source are required enums (see cheat sheet). Items are met_ ids.
ryot_q 'query($i:MetadataSearchInput!){ metadataSearch(input:$i){ response{ items } } }' \
  '{"i":{"lot":"BOOK","source":"OPENLIBRARY","search":{"query":"Dune Frank Herbert"}}}' \
  | jq -c '.data.metadataSearch.response.items'

# Confirm which is which before adding (details are wrapped in `response`):
ryot_q 'query($m:String!){ metadataDetails(metadataId:$m){ response{ id title lot publishYear } } }' \
  '{"m":"met_…"}' | jq -c '.data.metadataDetails.response'

# 2. Add to Watchlist (creatorUserId is your user id; entityLot METADATA)
ryot_q 'mutation($i:ChangeCollectionToEntitiesInput!){ deployAddEntitiesToCollectionJob(input:$i) }' \
  '{"i":{"creatorUserId":"usr_o04hupYGQWIM","collectionName":"Watchlist",
        "entities":[{"entityId":"met_…","entityLot":"METADATA"}]}}'

# Remove from Watchlist
ryot_q 'mutation($i:ChangeCollectionToEntitiesInput!){ deployRemoveEntitiesFromCollectionJob(input:$i) }' \
  '{"i":{"creatorUserId":"usr_o04hupYGQWIM","collectionName":"Watchlist",
        "entities":[{"entityId":"met_…","entityLot":"METADATA"}]}}'
```

- Both add/remove are **async "deploy" jobs** — they return `true` immediately;
  membership may take a second or two to appear.
- To wishlist into a different collection, swap `collectionName` (see the default
  collections below, or `userCollectionsList`).
- `entityLot` is `METADATA` for media. Other lots exist (`PERSON`, `METADATA_GROUP`,
  `EXERCISE`, `WORKOUT`) if you ever collect those.

## Query tracked data

```bash
# Your collections (id + name)
ryot_q 'query{ userCollectionsList{ response{ id name } } }' \
  | jq -c '.data.userCollectionsList.response'

# What's in a collection — e.g. everything on the Watchlist (resolve the id first
# via userCollectionsList). items[].entityId are met_/wor_/… ids you can detail.
ryot_q 'query($i:CollectionContentsInput!){ collectionContents(input:$i){
  response{ results{ details{ totalItems } items{ entityId entityLot } } } } }' \
  '{"i":{"collectionId":"col_…"}}' | jq -c '.data.collectionContents.response.results'

# Is a specific metadata item on any collection / seen? (wrapped in `response`)
ryot_q 'query($m:String!){ userMetadataDetails(metadataId:$m){
  response{ collections{ details{ collectionName } } hasInteracted } } }' \
  '{"m":"met_…"}' | jq -c '.data.userMetadataDetails.response'

# Body measurements (weight, body fat, …). Stat names are snake_case: weight, bmi,
# body_fat, body_water, muscle_mass, bone_mass, visceral_fat, basal_metabolic_rate, …
ryot_q 'query{ userMeasurementsList(input:{}){ response{ timestamp
  information{ statistics{ name value } } } } }' \
  | jq -c '.data.userMeasurementsList.response[-1]'   # most recent
```

Default collections (names are stable; ids differ per install — resolve via
`userCollectionsList` when you need an id): **Watchlist** (wishlist), **In Progress**,
**Completed**, **Owned**, **Reminders**, **Monitoring**, **Custom**.

### Bonus: log a body measurement

`information.assets` is **required** (send four empty lists); metrics go in
`statistics` as `{name, value}` with snake_case names (see above). Note: a Loftilla
scale already auto-logs weigh-ins (`project_scale_bridge`), so only add manual
entries on request. `timestamp` is the upsert key — reusing one overwrites it.

```bash
ryot_q 'mutation($i:UserMeasurementInput!){ createOrUpdateUserMeasurement(input:$i) }' \
  '{"i":{"timestamp":"2026-07-23T08:00:00Z","information":{
      "assets":{"s3Images":[],"s3Videos":[],"remoteImages":[],"remoteVideos":[]},
      "statistics":[{"name":"weight","value":"82.5"}]}}}'
```

## Cheat sheet: enums

GraphQL enums serialize **SCREAMING_SNAKE_CASE**.

- **`MediaLot`** (for `metadataSearch.lot`): `BOOK`, `MOVIE`, `SHOW`, `VIDEO_GAME`,
  `MUSIC`, `AUDIO_BOOK`, `ANIME`, `MANGA`, `PODCAST`, `VISUAL_NOVEL`.
- **`MediaSource`** (for `metadataSearch.source`) — pick one valid for the lot:
  `TMDB` (movies/shows), `OPENLIBRARY` / `GOOGLE_BOOKS` / `HARDCOVER` (books),
  `IGDB` (video games), `SPOTIFY` / `YOUTUBE_MUSIC` (music), `ANILIST` / `MYANIMELIST`
  (anime/manga), `LISTENNOTES` (podcasts).
- **`SetLot`**: `NORMAL`, `WARM_UP`, `DROP`, `FAILURE`.
- **`ExerciseLot`**: `REPS_AND_WEIGHT`, `REPS`, `DURATION`, `DISTANCE_AND_DURATION`,
  `REPS_AND_DURATION`, `REPS_AND_DURATION_AND_DISTANCE`.
- **`UserUnitSystem`**: `METRIC` (kg / km — the default here), `IMPERIAL` (lb / mi).

## Troubleshooting

- **Empty/`null` `data` with `errors`**: read `errors[].message` — usually a wrong
  field name, a required var missing, or an enum value that doesn't match the lot
  (e.g. `OPENLIBRARY` source with `MOVIE` lot). Introspect a type with
  `ryot_q 'query($n:String!){__type(name:$n){inputFields{name}}}' '{"n":"UserWorkoutInput"}'`.
- **`401` / auth errors**: `$RYOT_API_KEY` empty or revoked. Re-run the self-heal.
  To mint a fresh durable token you need an existing session token — log in with the
  admin creds (in `/run/agenix/ryot-import-env`, `ryot`-owned → needs sudo) then
  `mutation{ generateAuthToken }`, and store the result as `RYOT_API_KEY` in
  `picoclaw-env`. Prefer asking the user before rotating.
- **Wishlist add "did nothing"**: the deploy job is async — re-query
  `userMetadataDetails.collections` after a moment. Also confirm `creatorUserId` is
  **your** id (`usr_o04hupYGQWIM`) and `collectionName` is spelled exactly (`Watchlist`).
- **Workout has no exercises after create**: `exerciseId` didn't match a real
  exercise — resolve it via `userExercisesList` first (ids are names, case-sensitive).
- The web UI is at `https://rpi5.gate-mintaka.ts.net/ryot/` (Fitness → Workouts) to
  eyeball what you logged.
