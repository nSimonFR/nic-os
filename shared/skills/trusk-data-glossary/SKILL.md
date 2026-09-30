---
name: trusk-data-glossary
description: Translate Trusk business words into warehouse tables before querying Metabase — course, commande, ordermission / prestation, mission, tournée, task, user, and where each one's state lives. Use when a Metabase (or prod-warehouse) question is phrased in Trusk vocabulary ("combien de courses…", "commandes annulées", "prestations d'hier", "état de la mission", "users du BO"), or before choosing between two tables with the same name. Trusk only.
---

# Trusk business vocabulary → warehouse tables

All tables below live in the **Metabase warehouse, database id 6** (same data as the
`prod-warehouse` dbhub source on `toolhive-tech`). Verified 2026-09-30.

## Glossary

| Word people use | Table | Metabase id | Key |
| --- | --- | --- | --- |
| **course** | `trusk_fr_postgres_trusk_api.orders` | — ¹ | `id` (text, 10-char) |
| **commande** (IKEA / COA order) | `ikea_orders.log_order` | 668 | `id` (text) |
| **ordermission** — *prestation* in French | `journey_trusk_order.order_mission` | 657 | `id` |
| **mission** | `journey_trusk_order.mission` | 665 | `id` |
| **tournée** | `roundtrip.roundtrip` | 682 | `id` |
| **task** | `onfleet.task` | — ¹ | `id` |
| **user** | `identity_access_management.users` | — ¹ | `id` |
| states & statuses (all entities) | `state_status.statuses` | 708 | `(entity, entity_id)` |

¹ On the warehouse, but Metabase `search` doesn't return it, and it isn't in the id range
where the replicated schemas were synced (645–683, 708). So the notebook can't reach it:
query it through SQL (last section).

Not what they look like:

- `public.prod__orders` (536) is a same-shape copy of the courses. Use `trusk_fr_postgres_trusk_api.orders`: it is what `order_mission.trusk_order_id` joins to.
- `trusk_fr_postgres_trusk_api.users` (5.5M rows, customers and drivers) and `public.users` (43) are **legacy trusk-api users**. Only query them for a legacy question, and say so in the answer. A "user" is an IAM account: ~150 rows, `role` ∈ `Employee`, `Management`.
- `public.log_order` (443) is a second live copy of the commandes. Use `ikea_orders.log_order`, the replica of the owning service's schema. `ikea_orders.log_order_legacy` and `public.log_order_flat` / `log_order_statuses` are not the commande either.
- In general, when a name exists both in `public` and in a service schema (`ikea_orders`, `journey_trusk_order`, `roundtrip`, `state_status`…), use the service schema. The `public.*`, `prod__*` and `dbt__*` tables belong to DATA's pipelines.

## How they link

```
commande  ikea_orders.log_order.id ──< order_mission.log_order
course    trusk_api.orders.id      ──< order_mission.trusk_order_id   (nullable: ~55% of recent prestations)
mission   mission.id               ──< order_mission.mission_id
task      onfleet.task.service_id  →  mission.id  OR  trusk_api.orders.id
tournée   roundtrip.point.roundtrip_id → roundtrip.id ; point.order_id → mission.id OR trusk_api.orders.id
```

Measured 2026-09-30: every recent prestation joins its commande (4641/4641), and 8181/8205
`trusk_order_id` join a course. `task.service_id` is ~1/3 missions, ~2/3 courses, and
`point.order_id` about half each. Join both sides with `LEFT JOIN`, never one `INNER JOIN`.

## States — read `state_label` / `state_detail`

A **state** is the current lifecycle position (`WAITING/ASSIGNED`, `DELIVERED`, `FAILED/DROPOFF_FAILED`…).
state-status owns it; each owning service mirrors the latest one onto its row:

| Entity in `statuses.entity` | Mirror on the row | `entity_id` = |
| --- | --- | --- |
| `ORDER` | `log_order.state_label` / `state_detail` | commande id |
| `ORDERMISSION` | `order_mission.state_label` / `state_detail` | prestation id |
| `MISSION` | `mission.state_label` / `state_detail` | mission id **or course id** |
| `ROUNDTRIP` | `roundtrip.state_label` / `state_detail` | tournée id |
| `TASK` | none — `onfleet.task.status` is Onfleet's own field | task id |

- **Current state → the mirror columns.** For recently settled rows they matched the latest
  state-status row 100% (commandes 3889/3889, prestations 4567/4567, missions 1877/1877,
  tournées 593/593). They are one simple filter, which the Metabase notebook can build.
- **History, transitions, "when did it become X" → `state_status.statuses`.** `is_state = true`
  rows are states, `is_state = false` rows are statuses (events alongside the state).
  Latest = `ORDER BY date DESC`, not `created_at`. Label and detail are `status_label` / `status_detail`.
- **A course has no mirror column and no entity of its own.** Its state is under
  `entity = 'MISSION'`, `entity_id = orders.id`. `orders.status` (`WAITING`, `PROCESSING`,
  `ENDED`, `ABORTED`) is trusk-api's legacy status, and the two diverge: on 2026-09-30, 117
  `ENDED` and 40 `ABORTED` courses still had `WAITING/FOR_ROUTING` as their latest state. Say
  which one you used.
- A mirror can briefly lag state-status after a burst (see `notes/state-status-mirrors.md`).
  Anything touched in the last few minutes: prefer `statuses`.

## Legacy statuses on `log_order` — do not use

- **`log_order.statuses`** (jsonb, `{"data":[{"status":"order_created","date":…}]}`) is the
  pre-state-status history. Never read it for a state or a date; use `state_status.statuses`.
- `log_order.state` (`processable` / `cancelled`) is not the commande's state either: 39
  commandes were `cancelled` there while `WAITING/APPOINTMENT_VALIDATED` in state-status.
  Filter on `state_label`. It is still read by order-mission for IKEA, so it is not dead
  code — just not a reporting field.

## Querying through the Metabase MCP

- **Native SQL is refused**: `execute_query` on a native stage → `Native queries are not
  supported here; use execute_sql instead`. If no `execute_sql` tool is listed, run the SQL on
  `prod-warehouse` via `toolhive-tech` (`tech-dbhub_execute_sql_prod_warehouse`, 500-row cap).
- Single-table questions work in the notebook: `get_table {id, with-fields:true}` for field
  ids → `construct_query` (fields are `["field", <field_id>]`, never names) → `execute_query`.
  Use SQL for cross-table joins (commande ↔ prestation ↔ course) and for the tables marked ¹.
- `["time-interval", field, -1, "day"]` means **yesterday's calendar day**, not the last 24 h.
- Results come back in `Europe/Paris`; `execute_query` caps at 200 rows — aggregate first.
- `canceling statement due to conflict with recovery` on dbhub = standby killed a long query.
  Narrow the window (2 days → 6 hours sufficed for `roundtrip.point`).
- Before quoting a count, check freshness: `max(created_at)` vs `now()`. On 2026-09-30 the
  replicas were seconds behind, but lags of hours have happened (`notes/warehouse-replication.md`).
