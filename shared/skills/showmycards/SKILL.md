---
name: showmycards
description: Read and write the self-hosted ShowMyCards Magic-the-Gathering collection over its HTTP API — inventory, binders/boxes, decks (lists), Scryfall search — plus the Moxfield sync. Use when the user asks what cards they own, where a card is stored, to add/move/remove cards, to build or check a deck against their collection, or to sync with Moxfield.
metadata:
  short-description: ShowMyCards MTG collection + decks via its localhost HTTP API
---

# ShowMyCards

[ShowMyCards](https://showmy.cards) is the user's self-hosted MTG collection
manager, running natively on the rpi5 (`rpi5/showmycards.nix`). This skill drives
it over its HTTP API: what they own, where it physically lives, and how their decks
line up against it.

Current shape of the data, as a sanity baseline: **~171k card printings** in the
local catalogue (en + fr only — see Gotchas), **618 physical cards** in inventory
across **7 storage locations**, and **4 commander decks** stored as lists.

## Waking the service — read this first

There is **no authentication of any kind**. No token, no API key, no session. The
only thing standing between a caller and a full wipe is knowing the port, so treat
every write as unguarded (see ⚠️ Destructive operations).

The service is **asleep almost always**. It is socket-activated with a 600 s idle
timeout, and the backend is `partOf` the frontend, so both drop to ~0 RAM at rest.
That makes the port you choose load-bearing:

| address | behaviour |
|---|---|
| `127.0.0.1:8330` | ✅ **use this.** Socket-activation proxy — a connection wakes frontend + backend, waits for the ready probe, then forwards. |
| `127.0.0.1:13344` | ❌ backend's real bind. Cold = **connection refused**. Does not wake anything. |
| `127.0.0.1:13343` | ❌ frontend's real bind. Same problem. |
| `https://rpi5.gate-mintaka.ts.net:3550` | the human-facing tailnet URL. Works, but adds TLS + Tailscale for no benefit from on-box. |

The frontend proxies `/api/*` to the backend server-side, so `:8330/api/...` reaches
the whole API. **The first call after idle can take up to 60 s** (ready probe) — set
a generous timeout and do not mistake the delay for a hang.

⚠️ **A trailing slash returns an empty 308 through this proxy.** The SvelteKit
frontend normalises `/api/lists/` → `/api/lists` with a `308`, and `curl` does not
follow redirects unless told to. Because the body is empty and `-f` does not treat
3xx as an error, a trailing slash looks exactly like "the API returned nothing".
`-L` is therefore **mandatory** in the helper (the Go backend itself is
slash-agnostic; this is purely the proxy):

```bash
# NOTE: the local is `_p`, not `path`. In zsh (the shell here) `$path` is the array
# tied to $PATH, so `local path=…` blanks PATH inside the function and every command
# in it fails with "command not found: curl".
smc() {  # smc <path> [curl-args...]   e.g. smc /dashboard/stats
  local _p="$1"; shift
  curl -fsSL --max-time 180 -H 'Content-Type: application/json' \
    "http://127.0.0.1:8330/api$_p" "$@"
}

# Sanity check — wakes the service and proves the DB is attached
smc /health | jq -c    # {"status":"OK","version":"0.3.0","checks":{"database":"connected"}}
```

If you write curl by hand instead of using the helper, either keep `-L` or drop the
trailing slash. `--max-time 180` is not paranoia: a cold wake really can take ~60 s,
and a shorter timeout fails mid-probe.

## Exact request/response shapes

Do **not** trust prose (including this file) for field names. There is no OpenAPI
spec — upstream's `DEVELOPMENT.md` advertises Swagger UI at `/swagger`, but it does
not exist and the route 404s. The authoritative contract is the tygo-generated
TypeScript, shipped to a stable path by `rpi5/showmycards.nix` and regenerated from
the Go source on every version bump:

```bash
/etc/showmycards/api/api.ts       # handler request/response types + limit constants
/etc/showmycards/api/models.ts    # DB models (Inventory, List, ListItem, StorageLocation…)

grep -A8 'interface BatchMoveRequest' /etc/showmycards/api/api.ts
grep -E 'MaxBatchIDs|MaxBatchItems|CurrentExportVersion' /etc/showmycards/api/api.ts
```

If a call 400s on a field name, read those files rather than guessing.

## Reading the collection

```bash
smc /dashboard/stats | jq                      # totals: cards, value, locations, lists, unassigned
smc /storage/with-counts | jq -r '.[] | "\(.storage_type)\t\(.name)\t\(.card_count) cards"'
smc '/inventory/?page=1&page_size=100' | jq '.total_items'
smc '/inventory/cards?storage_location_id=3&page_size=50' | jq -r '.data[].name'
smc /inventory/by-oracle/<oracle_id> | jq     # every printing owned + which locations
smc '/inventory/?storage_location_id=null' | jq '.total_items'   # unassigned
```

⚠️ **Three different pagination envelopes** — check which one you are in:

| endpoint | envelope |
|---|---|
| `/inventory/`, `/storage/`, `/sorting-rules/`, `/sets/`, `/jobs/` | `{data,page,page_size,total_items,total_pages}` |
| `/inventory/cards`, `/lists/:id/items` | `{data,page,page_size,total_cards,total_pages}` |
| `/search` | `{data,page,total_cards,has_more}` — no `page_size`, no `total_pages` |
| `/lists/`, `/storage/with-counts`, `/banners` | **bare array**, unpaginated |

Params are always `page` + `page_size` (**never** `limit`/`offset`). Max page_size
is 100, except `/inventory/cards` which caps at **50**. `storage_location_id=null`
— the literal four-character string — is how you filter for unassigned.

## Searching for cards

`/search?q=` forwards `q` **verbatim to Scryfall**, so the full
[Scryfall syntax](https://scryfall.com/docs/syntax) works (`t:`, `c:`, `mv>=`,
`is:commander`, `-`, `OR`, `/regex/`, …), and results come back annotated with what
the user owns:

```bash
smc '/search?q=t%3Adragon+c%3Ared' | jq -r '.data[] | "\(.name) — own \(.inventory.total_quantity)"'
smc '/search/autocomplete?q=lightn' | jq -r '.suggestions[]'   # max 5, needs >=2 chars
```

⚠️ The saved setting `scryfall_default_search` (default `game:paper`) is **silently
appended to every query**, and a default language is appended unless `q` already
contains `l:`/`lang:`. So results are never purely what you asked for. Check with
`smc /settings/ | jq`.

`/cards/:id` takes a **Scryfall UUID** and fetches live from Scryfall (24 h cache),
not from the local catalogue.

## Binders and boxes (storage locations)

`storage_type` is exactly **`"Box"`** or **`"Binder"`** — capitalised,
case-sensitive, DB-enforced. Anything else 400s.

```bash
smc /storage/ -X POST -d '{"name":"Blue Dragon Shield","storage_type":"Binder"}'
smc /storage/5 -X PUT  -d '{"name":"Renamed","storage_type":"Binder"}'
smc /storage/5 -X DELETE      # 409 if anything still references it
```

`DELETE /storage/:id` is the **only** delete in this API with a referential guard:
it refuses with `409` and `{"inventory_count":N,"sorting_rule_count":M}` while cards
or rules point at it. Note PUT cannot clear a field — empty values are ignored — and
**names are not unique**, so creating the same binder twice gives you two.

## Placing cards ⭐

```bash
# add one card to a location (quantity 0 is coerced to 1)
smc /inventory/ -X POST -d '{"scryfall_id":"…","oracle_id":"…","treatment":"nonfoil","quantity":2,"storage_location_id":3}'

# move whole rows between locations
smc /inventory/batch/move -X POST -d '{"ids":[12,13,14],"storage_location_id":5}'
smc /inventory/batch/move -X POST -d '{"ids":[12],"storage_location_id":null}'   # unassign
```

⚠️ **Batch-move moves WHOLE ROWS ONLY.** `BatchMoveRequest` has no quantity field.
To split a stack — say 33 Plains where 15 belong in another binder — it is two
steps, and there is no single-call alternative:

```bash
smc /inventory/42 -X PUT -d '{"quantity":18}'                     # decrement source
smc /inventory/ -X POST -d '{"scryfall_id":"…","oracle_id":"…","treatment":"nonfoil","quantity":15,"storage_location_id":5}'
```

Also worth knowing: `POST /inventory/` with **no** `storage_location_id` silently
runs the sorting rules and puts the card wherever they say (or leaves it
unassigned if none match). There is **no uniqueness constraint on inventory**, so
repeated POSTs create duplicate rows rather than merging quantities — always search
before adding. `PUT /inventory/:id` needs at least one field, and `clear_storage:
true` beats `storage_location_id`.

## Decks and wantlists (lists)

A deck is a **list**; each item is a specific printing with a desired vs collected
quantity. Convention in this repo: the deck's Moxfield URL is stored in the list
`description`, which is what the Moxfield sync matches on.

```bash
smc /lists/ | jq -r '.[] | "\(.id)\t\(.name)\t\(.total_cards_collected)/\(.total_cards_wanted)"'
smc /lists/ -X POST -d '{"name":"Pixie Dust","description":"https://moxfield.com/decks/…"}'
smc '/lists/4/items?page_size=100' | jq -r '.data[] | "\(.desired_quantity)x \(.name)"'
```

Adding items — **the only way in** is the batch endpoint; there is no single-item
POST:

```bash
smc /lists/4/items/batch -X POST -d '{"items":[
  {"scryfall_id":"…","oracle_id":"…","treatment":"nonfoil","desired_quantity":1}
]}'
smc /lists/4/items/91 -X PUT -d '{"collected_quantity":1}'
smc /lists/4/items/91 -X DELETE
```

Three traps:

1. Max **500** items per batch call.
2. Unique index on `(list_id, scryfall_id, treatment)` — **one duplicate anywhere in
   the batch fails the entire transaction** with an opaque 500. De-duplicate and
   merge quantities before sending.
3. `collected_quantity` is **forced to 0 on create** — you cannot seed it. Set it
   afterwards per item with `PUT`, and note the model rejects
   `collected_quantity > desired_quantity`.

**`oracle_id` is mandatory** on both inventory and list items, and external sources
(Moxfield) often omit it. Resolve it from the local catalogue:

```sql
-- sudo sqlite3 "file:/mnt/data/showmycards/database.db?mode=ro"
select oracle_id from cards where scryfall_id = '…';
```

Judging "do I own this deck?" turns on which id you match. `scryfall_id` answers
*"do I own this exact printing"*; `oracle_id` answers *"can I build this deck"*.
They differ a lot in practice — one of this user's decks reads 54/100 by printing
but 100/100 by card. **The Moxfield sync writes `collected_quantity` at oracle
level**, so a list's `x/y` means "cards I can physically put in this deck", any
printing, any finish. Never infer printing-level ownership from a list's collected
count — query `/inventory/by-oracle/<oracle_id>` and read the printings out.

## Bulk import / export

```bash
smc /data/export > backup.json
smc /data/import -X POST -d @payload.json
```

⚠️ `POST /data/import` is **additive only** — it never merges, never replaces, and
there is no reset endpoint. Importing the same file twice **duplicates every storage
location, rule, list and inventory row** (only list items de-dup, via their unique
index). Use it to seed, never to reconcile. Payload is the v1 envelope
(`version`, `storage_locations`, `sorting_rules`, `lists`, `inventory`), where
`ref_id` values are internal join keys remapped on insert. Body limit 50 MB.

## ⚠️ Destructive operations

No soft-delete exists anywhere in this schema. Nothing here is recoverable without
a backup. **Confirm with the user before any of these:**

| call | what it actually does |
|---|---|
| `POST /inventory/resort` with `{}` or no `ids` | Re-evaluates **every inventory row in the DB** and **NULLs the location of anything no enabled rule matches**. A thin rule set mass-unassigns the whole collection. |
| `DELETE /inventory/batch {"ids":[…]}` | Up to **1000 hard deletes** per call, returns `200`. Note: a DELETE with a JSON body. |
| `DELETE /lists/:id` | Deletes the list **and every item in it**. |
| `PUT /lists/:id {"name":"x"}` | **Wipes `description`** — it is a non-pointer field, so omitting it writes empty. Always send both. For this repo that silently destroys the Moxfield URL the sync relies on. |
| `PUT /settings/scryfall_default_search` | Silently changes the results of every future search. |
| `DELETE /jobs/cleanup?retention_days=1` | Purges job history. |

Before a bulk write, snapshot: `smc /data/export > /tmp/smc-$(date +%s).json`.

## Sorting rules

Rules auto-place new cards. The expression language is **[expr-lang](https://expr-lang.org)
— not Scryfall syntax** — and must evaluate to a boolean.

```bash
smc /sorting-rules/validate -X POST -d '{"expression":"rarity == \"mythic\""}'
smc /sorting-rules/evaluate -X POST -d '{"card_data":{"rarity":"rare","colors":["U"]},"treatment":"foil"}'
```

In scope: strings `name rarity set set_name type_line oracle_text mana_cost power
toughness artist collector_number frame border_color layout treatment`; numbers
`cmc edhrec_rank`; booleans `reserved foil nonfoil oversized promo reprint digital
full_art booster`; arrays `colors color_identity keywords finishes promo_types`;
map `prices.{usd,usd_foil,usd_etched,eur,eur_foil,tix}`; helpers `hasColor(c)`,
`isMonoColor()`, `isMultiColor()`, `isColorless()`, `isColor(...)`.

Gotchas: `prices.usd` is **`nil` when Scryfall has no price**, so `prices.usd > 5`
throws at runtime — guard with `prices.usd != nil && prices.usd > 5`. Lowest
`priority` wins, first match only. And `PUT /sorting-rules/:id` **does not
re-validate the expression**, so an invalid one persists and is then silently
skipped at evaluation time.

## Moxfield sync

Decks live on Moxfield; the sync pulls them into lists. Run it on demand after
editing a deck there (it also runs on a daily timer):

```bash
sudo systemctl start moxfield-sync
journalctl -u moxfield-sync -n 40 --no-pager
```

Ownership on the synced items is oracle-level: printings of one card share a single
pool within a deck (8 Forests wanted across two printings with 5 owned is 5
collected, not 5 + 5), and pools are *not* shared between decks — each deck answers
"can I build this one", so a single copy counts in every deck that wants it.

It is **pull-only by design.** Writing to Moxfield needs a Bearer token whose
issuing endpoint is gated by a Cloudflare Turnstile CAPTCHA — unsolvable
server-side, confirmed by an open report from a developer with a whitelisted
User-Agent on Moxfield's own tracker — and their ToS prohibits automated access
without written permission. So the push direction generates files the user uploads
by hand, into `/mnt/data/moxfield-export/`: a `collection.csv` in Moxfield's
documented column format and one bulk-edit `.txt` per deck.

⚠️ Moxfield's collection import **adds, never replaces**. Re-uploading
`collection.csv` duplicates quantities; removals cannot be expressed at all. Tell
the user that before they upload a second time.

## MTG rules/pricing tools — Hermes only

The `mtg` MCP server (Scryfall + EDHREC + rules + deck validation) is wired **only
for the Hermes agent** (`rpi5/hermes/hermes.nix`, stdio transport, no port). If you
are Hermes, `mcp__mtg__*` tools are available. **Every other agent — Claude Code,
Codex, Pi — does not have them**; do not try to call them. Use `/api/search`
(Scryfall-backed, and it annotates ownership) or `https://api.scryfall.com` directly.

## Gotchas

- **The catalogue is en + fr only.** The Scryfall import is patched to keep just
  those languages (171 158 of 535 598 printings) — see `pkgs/showmycards.nix`. A
  card in any other language resolves to nothing, and endpoints silently drop rows
  whose `scryfall_id` is absent from the local `cards` table while still counting
  them in `total_cards`.
- **Never let a bulk import get killed.** `TriggerInitialImport` is gated on "are
  there any card rows", not "is the import complete", so a partial import is sticky
  forever: every later start logs `bulk data already exists, skipping initial
  import`. Recovery is wiping `/mnt/data/showmycards/database.db{,-wal,-shm}` and
  re-running — hours on this hardware.
- **The DB is on `/mnt/data`, never `/`.** Root is ~96 % full; importing the card
  catalogue to `/` is what filled it on 2026-07-26.
- Both `/api/inventory` and `/api/inventory/` work (non-strict routing).
- Reading SQLite directly is fine **read-only** (`?mode=ro`, as user `showmycards`
  or root) for joins the API cannot express. Write through the API instead — the
  backend holds a WAL connection.

## Troubleshooting

- **`connection refused`** → you used `:13344`/`:13343`. Use `:8330`.
- **First call times out** → ready probe, up to 60 s from cold. Retry with a longer
  timeout before concluding anything is broken.
- **`500` from `/lists/:id/items/batch`** → duplicate `(scryfall_id, treatment)` in
  your batch, or one already present in that list. The whole transaction rolled back.
- **`409` from `DELETE /storage/:id`** → cards or rules still reference it; the
  response body tells you how many.
- **`data` shorter than `total_cards`** → those printings aren't in the local
  catalogue (non-en/fr, or catalogue predates the set).
- **A card "vanished" after adding it** → a sorting rule placed it somewhere
  unexpected, or none matched and it is unassigned:
  `smc '/inventory/?storage_location_id=null'`.
- **Search returns nothing plausible** → `scryfall_default_search` is being appended;
  check `smc /settings/ | jq`.
