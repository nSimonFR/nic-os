# Schema migrations

Triggers: editing anything under `schema/migrations` · `42703 column does not exist` after a deploy · `_migrations` table · schema drift between envs · `ALTER COLUMN … TYPE` · `AccessExclusiveLock` · `lock_timeout` · pg-migrate → TypeORM · `lib-pg-migrate` · `_knex_migrations` · `migration:run --fake` · init container replays `CREATE TABLE` · `OmitType` `Cannot read properties of undefined (reading 'prototype')` during `migration:run` · `42501 permission denied for table shipment_site` · `CreatePlanConfig20260921100000` · cross-schema foreign key

## `ALTER COLUMN ... TYPE numeric(p,s)` réécrit la table dès que le scale change

`ADD COLUMN` nullable sans default est une opération de métadonnée (instantané). `ALTER COLUMN ... TYPE` sur un `numeric` dont le **scale** change ne l'est pas : PostgreSQL réécrit toute la table sous `AccessExclusiveLock`, ce qui bloque lectures ET écritures pendant la réécriture. `SET LOCAL lock_timeout` borne **l'attente du verrou, pas la réécriture** — ne pas le lire comme une garantie de durée. Mesure de référence (order-mission, `mission`, `fee_percent` `decimal(10,2)` → `(10,4)`, 2026-08-31) : 64 341 lignes / 70 MB ⇒ quelques secondes. Vérifier aussi que les données passent la nouvelle contrainte avant : `precision 10, scale 4` ne laisse que 6 chiffres entiers.

## Migration footgun — never add steps to an already-applied migration

TypeORM/knex track migrations by name+timestamp. If a migration already ran (its row is in `_migrations`) and you later **add steps to that same file**, every env that recorded it **skips the new steps** → silent schema drift. Real case (state-status, 2026-07): the `label→status_label` / `detail→status_detail` rename was folded into the already-run `1782` split-drop-code migration. Staging had run 1782 **pre-rename** (the manual "run the migration in staging" step during review) → the 1.33.x redeploy saw 1782 in `_migrations` and skipped it → columns stayed `label`/`detail` while the entity mapped `status_label`/`status_detail` → **every write threw `42703 column status_label does not exist`** (TypeORM's post-insert entity reload). CI didn't catch it (CI builds the schema fresh from the full current migration; only envs with the stale recorded row drift). **Fix = a NEW idempotent migration** (rename only `IF EXISTS old_col AND NOT EXISTS new_col`, via a `DO $$ … $$` block) — never re-edit the applied one. Prod is safe if it never ran the intermediate version (it runs the complete migration once); the idempotent follow-up protects both.

## pg-migrate (knex) → TypeORM cutover

Every internal service runs TypeORM migrations since IN-946 (2026-09): COA (IN-807), state-status,
roundtrip (IN-1053), order-mission (IN-1054). Runbook with the pre-flight query and the Job manifest:
`<repo>/docs/migration-cutover.md` in any of them.

- **Each env must be backfilled before the first deploy.** Existing DBs record history in
  `<schema>._knex_migrations`; TypeORM reads `<schema>._migrations`, which is empty. Without the
  backfill the init container replays every `CREATE TABLE`, crashes, and the pod never starts. Fill it
  with a one-off Job built from the running init container's spec (same `envFrom`/`env`), using the new
  image, running `npm run migration:run -- --fake`. That writes one row per migration in a single
  transaction and runs no DDL. Never hand-write the rows: `migration:revert` relies on the exact
  `(timestamp, name)` pairs. The old pgm init container ignores `_migrations`, so backfilling early is
  harmless, but a pgm migration deployed after the backfill is missing from it. Run `--fake` again
  right before the cutover.
- **Stored timestamps are 13 digits.** TypeORM parses the last 13 digits of the class name, so
  `Init20240701120000` is stored as `240701120000`. That's expected, and the ordering holds (seen on
  COA, order-mission and roundtrip).
- **The CLI loads every `dist/**/*.entity.js` in filesystem order**, not the order the app imports
  them. A circular import between entities that the app survives can crash `migration:run`. Case
  roundtrip 2026-09-25: `point.entity` loaded first, `roundtrip.entity` ran `OmitType(Point, …)` in a
  decorator while `Point` was still `undefined`, giving `TypeError: Cannot read properties of undefined
  (reading 'prototype')`. It passed CI, tests and a local docker run, and failed only on the staging
  `--fake` Job. Fix: build the type lazily (`type: () => [memoisedOmitType()]`). Probe before shipping:
  `node -e 'require("reflect-metadata"); require("./dist/src/point/point.entity.js")'`.
- **A cross-schema relation needs `TYPEORM_CROSS_SCHEMAS`.** roundtrip's shared entity points at a
  fleet table, so its `typeorm` script sets `TYPEORM_CROSS_SCHEMAS=fleet`; without it the CLI fails with
  `Entity metadata for … was not found`.
- **A preview created before the cutover keeps its knex history too.** Its init container
  replays `Init…` and dies on `relation "journey_order" already exists` (order-mission 1.74.0 on
  `pr-in1047`, 2026-09-25). A preview created after the cutover replays all migrations from scratch
  and needs nothing. For an old preview, either run the `--fake` Job there, or pin the service (chart
  `targetRevision`, `image.tag` **and** `truskInitContainers[0].image`) to the last pre-cutover tag.
  The chart changed in the same commit (`order-mission-pgm` → `order-mission-typeorm-migration`), so
  pinning only the image isn't enough.
- Leftovers after a cutover: inert `_knex_migrations` / `_knex_migrations_lock` tables (dropping them
  is a separate DB write), and prod `state_status._migrations` holds
  `UnifySourceLabelEnumMigration1784500000000` twice (ids 17/18, staging has one). Both tracked in
  IN-1055.

## Cross-schema foreign keys need a grant from the owning role

A migration that adds a FK to another service's table needs `REFERENCES` on that table, and only the
table's **owner** can grant it. `pg_write_all_data` (the `mcp_readwrite` role behind
`postgres_staging_rw`) can't. Without the grant, `migration:run` fails with `42501 permission denied
for table <t>`. The pod never starts, and CI stays green because CI builds a fresh schema as a
superuser.

Real case: COA's TransportPlan (`CreatePlanConfig20260921100000`, IN-932, released in 4.76.0) points
at `interop_configuration.shipment_site` and `.contract`. Neither the PR nor interop-configuration
shipped the grant. Result: COA crash-looped on staging when the 2026-09-28 batch rolled out, and on
every preview running COA's `master` migrations.

The app role is `centiro_orders` on staging (`POSTGRES_USER` in the pod) and `ikea_orders` on
previews. Grant it as the owner, from the owner's own pod:

```bash
# in the interop-configuration pod (its POSTGRES_USER owns the tables); assert the DB first
node -e 'const {Client}=require("pg");const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});
(async()=>{await c.connect();await c.query("GRANT REFERENCES ON interop_configuration.shipment_site, interop_configuration.contract TO centiro_orders");await c.end()})()'
```

Check it: `select has_table_privilege('centiro_orders','interop_configuration.shipment_site','REFERENCES')`.
Done on staging 2026-09-28. **Prod needs it before COA ≥ 4.76.0 ships.** Previews still lack it.
