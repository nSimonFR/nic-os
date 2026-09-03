# Replication prod → warehouse: pglogical, and the DDL side-channel

Triggers: a schema change is missing on the warehouse · `pgreplication.ddl_log` · `applied_at` / `executed_sub` NULL · `unknown column name <col>` in the subscriber log · pglogical slot frozen, `confirmed_flush_lsn` not moving · `wal_status = extended` · tens of GB of WAL retained on prod · `pgl_warehouse_trsk_prod__trusk_sub__*` · `old_wh_warehouse` · about to replay `ddl_log` by hand · apply worker restarting every ~10-15 min with no visible error

Written 2026-09-03 from a live incident. Sections marked **HYPOTHESIS** were not confirmed — do not quote them as fact.

## Topology

- **Provider**: mutualised prod PG (`postgres-trusk-production`), pglogical node `trsk_prod__trusk` (node_id 1433463987).
- **Slot**: `pgl_warehouse_trsk_prod__trusk_sub__trse103afe`, plugin `pglogical_output`, subscriber `sub__trsk_prod_trusk__old_wh_warehouse`.
- **`pg_publication` is EMPTY** — this is pglogical, not native logical replication. Do not look for publications.
- **Replication sets**: one per schema (`ikea_orders_set`, `journey_trusk_order_set`, `fleet_set`, `state_status_set`, `wms_set`, `interop_engine_set`, `interop_configuration_set`, `communications_set`, `estimator_set`, `identity_access_management_set`, `onfleet_set`, `rating_set`, `roundtrip_set`, `billing_set`) plus `default`, `default_insert_only`, and **`ddl_sql` / `ddl_set`** which carry the DDL. Test sets `foo_set`, `testoo_set`, `functest_set` also exist.
- `pglogical.tables` and `pglogical.subscription` are **permission denied** for application roles — you cannot enumerate set membership or subscriptions from a service pod. `pglogical.replication_set_table` IS readable (columns: `set_id`, `set_reloid`, `set_att_list`, `set_row_filter`).

**Despite its name, `old_wh_warehouse` is LIVE and in use** (confirmed by Arthur Nguyen / DATA, 2026-09-03). Do not propose dropping the slot on the assumption that it is decommissioned.

## PG does not replicate DDL — the workaround

Three event triggers, all `ENABLED`, feed `pgreplication.ddl_log`:

| trigger | event |
| --- | --- |
| `auto_replicate_ddl_trigger` | `ddl_command_end` |
| `auto_replicate_drop_trigger` | `sql_drop` |
| `snapshot_orphans_pre_trigger` | `ddl_command_start` |

`ddl_log` columns: `id, queued_at, search_path, command_tag, object_type, object_identity, executed_prov, executed_sub, replication_set, ddl_text, auto_apply, applied_at, apply_error`.

### One row per SUBMITTED STATEMENT, not per object

`auto_replicate_ddl` (313 lines, read it via `pg_proc`) does `ddl_text := current_query()`, dedupes on `pgreplication._last_ddl_text`, and inserts only `IF NOT queued`. So a migration whose whole body is one `queryRunner.query()` produces **a single row carrying all of it**, and `object_identity` names only the first object touched.

Proof: row `id=486` (`CreateDeliveryZone20260715143124`) is **1658 chars and contains 3 `CREATE TABLE`** — `delivery_zone`, `delivery_zone_clients`, `delivery_zone_shipment_sites`. Only the first is in `object_identity`.

**Always inspect `ddl_text`. Never conclude anything from `object_identity` or from a row count.** A schema with 7 rows is not "less replicated" than one with 873 — `wms`'s 873 are mostly the same `CREATE FUNCTION wms.update_updated_at_timestamp_on_update()` replayed over and over.

Seeds and backfills are **DML**: no DDL event fires, nothing lands in `ddl_log`, and that is correct. They travel in the normal row stream. A migration split across several `queryRunner.query()` calls therefore has only its DDL statements captured — e.g. `AddInitialAddress20260827120000` yields one 135-char row with the `ALTER`, and its backfill `UPDATE` is absent by design.

### `applied_at` / `executed_sub` on the provider mean NOTHING

Both are NULL on **every** row (1257 as of 2026-09-03, back to 2026-06-21), and `apply_error` is empty throughout. **Do not infer "nobody consumes the queue" from this** — that inference was made during this incident and was wrong. DATA replays pending DDL by hand, and a manual replay never writes back into the provider's copy. These columns are write-only from the provider's point of view.

## The 2026-09-03 incident, and the rule it teaches

Subscriber log (Cloud SQL):

```
ERROR: unknown column name flow_delivery_zone_legacy
```

That is the pglogical apply worker receiving a change whose column list includes a column **absent from the local table**. Direction matters: the change has it, the subscriber does not.

Cause: a manual `ddl_log` replay applied `ReplaceFlowDeliveryZoneDualWithId20260728093000` — which ends in `DROP COLUMN flow_delivery_zone_legacy, flow_delivery_zone_api` — **ahead of the un-replayed DML backlog**. That backlog was captured while the columns still existed, so every change referencing them now fails, forever.

**The rule: in the normal stream, DDL and DML are consistent by construction** — the `ddl_log` row is replicated at the LSN of the migration. **A manual batch replay breaks that ordering** and projects the schema ahead of the data. It converts a recoverable lag into an unrecoverable one. If you must replay, replay strictly in LSN order and never ahead of the DML position.

Aggravating factor: **a migration's nominal timestamp is not its execution date.** `…20260728093000` ran on 2026-09-03 because prod sat on 4.66.10 and the migration shipped in 4.67.0. So the columns existed on the provider from 2026-07-29 (`ddl_log` 487) to 2026-09-03 07:32 (`ddl_log` 2815) — five weeks of DML carrying them. Ordering by migration name would have looked fine and still been wrong.

## Why the apply worker is never "down", and why it restarts every ~x minutes

- It is a **background worker with a restart time**: on ERROR/FATAL it exits and the pglogical manager relaunches it. It is in a **crash-loop**, never `down`. Visible from the provider only as a rotating walsender pid (observed 1608858 → 1609939 → 1619139 → 1626736 in ~40 min).
- **Its errors are in the SUBSCRIBER's Postgres log** (Cloud SQL), never in `ddl_log.apply_error`, which belongs to the DDL-apply mechanism. An empty `apply_error` is an absence of information, not an absence of error. Also check `pg_stat_subscription` and `pglogical.local_sync_status` on the subscriber.
- The restart period is **not** the time to detect the error — it is the time to *reach* it. Logical decoding restarts from `restart_lsn`; with that frozen 41 GB behind, each attempt re-reads and reassembles ~41 GB before hitting the bad change. **Testable prediction: the cycle lengthens as the gap grows.**

**HYPOTHESIS** — the precise trigger of a ~10-15 min cycle was never confirmed. `lock_timeout = 600000 ms` (10 min) is the **only** non-default timeout on the warehouse and is set in its config file; a worker blocking on a lock and hitting it would fit. Look for `canceling statement due to lock timeout` in the subscriber log. Ruled out on both sides: `statement_timeout`, `idle_in_transaction_session_timeout`, `transaction_timeout`, `idle_session_timeout` = 0, `wal_sender_timeout` / `wal_receiver_timeout` = 60 s. Nothing is set to 900 s.

## Numbers, 2026-09-03 ~14:00 UTC

```
restart_lsn        26F/C4D9D4E0   frozen
confirmed_flush    277/6F430E80   frozen
WAL retained       41 GB
real lag           10 GB, growing
wal_status         extended
safe_wal_size      159 GB   (max_slot_wal_keep_size = 200 GB, max_wal_size = 1.5 GB)
ddl_log            1257 rows, all applied_at NULL
```

At 200 GB the slot flips to `lost` and PG frees the WAL — replication is then gone for good. Prod writes ~7 MB/min off-peak, so there are days of margin, not hours.

**HYPOTHESIS — the un-poisoning fix**, proposed but neither executed nor validated: re-create the two dropped columns on the **subscriber** (nullable, no default → metadata only), let the backlog drain past the DROP's LSN, then drop them again. Cheaper than the alternative, a full resync (`ikea_orders` alone is 33 GB / 14 tables; `log_order` 11 GB + 3.1 GB of indexes; whole `trusk` DB 54 GB).

## Querying the two databases

`psql` is absent from the Node alpine images. Use the in-image `pg` driver, and **force the cwd** or module resolution breaks:

```bash
kubectl --context "$CTX" -n production exec <pod> -c <container> -- node -e '
process.chdir("/app"); const {Client}=require("/app/node_modules/pg");
const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,
  password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});
(async()=>{await c.connect(); /* ... */ await c.end();})().catch(e=>{console.error(e.message);process.exit(1)});'
```

**Warehouse** — credentials sit in any `fleet` prod pod: `WAREHOUSE_DATABASE_HOST=trusk-data-warehouse-pg.trusk.com`, port `5432`, user `production_reader`, password in the env. `WAREHOUSE_DATABASE_NAME` is **empty** — the database is `warehouse` (others: `postgres`, `cloudsqladmin`). Needs `ssl: {rejectUnauthorized:false}`.

**`production_reader` cannot see the replicated schemas.** No `log_order`, no `mission`, `ikea_orders` has 0 tables. It only sees ETL targets — `trusk_fr_postgres_trusk_api`, `trusk_fr_postgres_common_v2/v3`, `trusk_fr_postgres_cresus_replica_v2`, `zendesk_support_prod`, `aircall`, `metabase`, `compliance`, `typeform_*`. **Confirming anything about the pglogical target requires another account**; the request was still open on 2026-09-03.

Shell-quoting traps inside `node -e`: `interval '30 days'` breaks — use `make_interval(days => 30)`. `replace(x, chr(10), ' ')` breaks — clean up in JS instead. `pyyaml` is not installed on the host.

## Two methodological traps this incident produced

**Do not date a replication freeze from a spot WAL rate.** Dividing a 10 GB lag by 7.4 MB/min measured over 60 s at midday gave "24 h", which exonerated the guilty migration. The window actually contained a migration spike — `AddInitialAddress` rewrote **953 859 of 1 812 723** `log_order` rows, several GB of WAL in one pass. The real answer was ~5 h. Either bound the estimate with the known spikes, or find the freeze in the subscriber log.

**`distinctPatterns` in a Datadog `search` describes the sample, not the population.** A pattern "appearing" in a later sample is not a new pattern; check it with a 7 d `aggregate` grouped by `@version` before calling it a regression.

## Not the culprit, but worth knowing

`centiro-orders-api/docs/fake-migrations-job.yaml` defines a prod Job running `npm run migration:run -- --fake` from image **4.61.0**. `--fake` stamps migrations as applied **without executing their SQL** — a `_migrations` table that lies. Checked on 2026-09-03: not the case here, all 39 recorded COA migrations do have their DDL in prod. Keep the reflex: facing a suspicious `_migrations`, look for that job before concluding.

See also [`schema-migrations`](schema-migrations.md) and [`data-and-analytics-mcp`](data-and-analytics-mcp.md).
