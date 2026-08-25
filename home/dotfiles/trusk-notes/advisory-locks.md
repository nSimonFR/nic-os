# Advisory locks — `@trusk-official/nestjs-sql` `LockService`

Triggers: `lockBuilder` · `advisory-lock pool saturated` · `timeout exceeded when trying to
connect` · `55P03` · `POSTGRES_LOCK_POOL_MAX` · service wedged under concurrency · AMQP acks
at 0.

## Mechanics

`lockBuilder(key, fn)` → `pg_advisory_lock(hashtext(prefix:key))` on a **dedicated pg pool**,
separate from TypeORM's.

| knob | default |
| --- | --- |
| `POSTGRES_LOCK_POOL_MAX` | 5 **per pod** |
| `POSTGRES_LOCK_ACQUIRE_TIMEOUT_MS` | 10 s |
| `-c lock_timeout` on the lock pool | = acquire timeout, since 11.9.2 → `55P03` |

Why a separate pool: taking the lock on a `QueryRunner` from the *same* pool means every
connection ends up parked holding a lock while the guarded work waits for a connection that
never frees. Prod, state-status, 2026-06-15: 10 idle connections/pod all on
`SELECT pg_advisory_lock(...)`, ack rate 0.

## Two failure modes — different problems

### Same key nested → deadlock. No pool size fixes it.

Inner take runs on a second connection, waits on the lock the outer frame holds; outer waits
on inner. Circular. Pool of 1000 → 1000 parked connections.

Symptom depends on version:

| version | symptom to look for |
| --- | --- |
| < 11.9.2 | two slots frozen **permanently**; old locks on `idle` connections; ack rate 0 |
| ≥ 11.9.2 | inner take fails `55P03` after the acquire timeout → **retry churn, young lock ages**. Bug identical, every execution still fails. |

Case: `createFromOrderMission` wrapped `this.delete(id)` in ``lockBuilder(`mission:${id}`)``;
`delete` takes the same key. Triggered by ordinary traffic (log_order deleted/cancelled while
its mission exists). [IN-873](https://linear.app/trusk/issue/IN-873) ·
[order-mission#252](https://github.com/trusk-official/order-mission/pull/252) · fixed in 1.54.1.

### Different keys nested → capacity. Sizing fixes it.

> **pool ≥ prefetchCount × nesting depth**

order-mission: handlers take `orderMission:<id>` → `createFromOrderMission` takes
`mission:<id>` (depth 2), `prefetchCount: 5` → minimum 10, default was 5.

Self-sustaining: starvation → job fails → retried (**up to 100×**) → each retry asks for a
lock again. **A restart does not clear it** — measured: pool back to 10/10 within 5 min of
`rollout restart`, no test running.

Measured both directions, staging 2026-08-24: pool 5 → permanent saturation; pool raised →
**0 saturation errors / 1078 log lines**.
[IN-871](https://linear.app/trusk/issue/IN-871) ·
[order-mission#256](https://github.com/trusk-official/order-mission/pull/256) sets
`POSTGRES_LOCK_POOL_MAX=15`.

## No network calls inside a lock

10 slots cluster-wide × 10 s HTTP call inside = **1 locked op/sec**, whatever the pool size.

Rule: inside the lock, local state transitions only. Remote **reads** hoisted + re-validated.
Remote **writes** moved out.

- Remote read feeding the serialized decision → hoist + re-validate under the lock, fetch
  only on mismatch. Reference: `mission.service.update`'s `prefetchAvailability` (carries the
  id the fetch was made for, so the critical section can detect a stale prefetch).
- Remote write → never atomic with the DB write anyway. Out, with idempotency/compensation.

Outstanding 2026-08-25: `upsertTruskOrder` makes 3 outbound calls under `orderMission:<id>`
(centiro `getOrder`, trusk-api, interop `getContract`); `createFromOrderMission` calls
`getCustomerId` there too. [IN-878](https://linear.app/trusk/issue/IN-878) = same defect in
`mission-reset.reset()`.

## Sites to audit

- `trusk-api/assignation.js:162-170` — `syncAssignedOrder(...)` called without
  `await`/`return`, so the lock releases before the guarded work starts. Verified in source,
  unticketed.
- centiro ADR-002 documents an already-fixed defective key as accepted design.

## Helpers

`withEntityLock` / `tryEntityLock` (11.10.0,
[trusk-lib#886](https://github.com/trusk-official/trusk-lib/pull/886)) take the lock on the
caller's `EntityManager` via `opts.manager` — one connection, not two. Prefer when the
guarded work is already in a transaction.

## Diagnose

```sql
select a.application_name, a.state, count(*),
       max(round(extract(epoch from now() - a.state_change))) oldest_s
  from pg_locks l join pg_stat_activity a using(pid)
 where l.locktype = 'advisory'
 group by 1, 2 order by 3 desc;
```

`<service>-locks` at its max = saturated. Young ages = retry churn. Old ages on `idle` = hang.
