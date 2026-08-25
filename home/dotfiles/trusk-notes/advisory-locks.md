# Advisory locks (`@trusk-official/nestjs-sql` `LockService`)

Applies to every service using `lockBuilder`. Learned the hard way over IN-871 / IN-873
(2026-08). The one-paragraph version lives in `../CLAUDE.md`; this is the full account.

## How it works

`lockBuilder(key, fn)` takes `pg_advisory_lock(hashtext(prefix:key))` on a **dedicated pg
pool**, separate from TypeORM's. That separation is deliberate — the original design took
the lock on a `QueryRunner` from the *same* pool, so under concurrency every connection
ended up parked holding a lock while the guarded work waited for a connection that would
never free. Observed in prod (state-status, 2026-06-15): 10 idle connections per pod, all
on `SELECT pg_advisory_lock(...)`, AMQP ack rate 0.

- Default pool max: **5 per pod**. Override: **`POSTGRES_LOCK_POOL_MAX`**.
- Acquire timeout: `POSTGRES_LOCK_ACQUIRE_TIMEOUT_MS`, default 10 s.
- Since 11.9.2 the lock pool is opened with `options: -c lock_timeout=<acquireTimeoutMs>`,
  so a *wait on the lock itself* is bounded too and surfaces as SQLSTATE **`55P03`**.
  Before that, `connectionTimeoutMillis` guarded only `pool.connect()`, never the
  `SELECT pg_advisory_lock(...)` — which is why a nested same-key take hung forever.

## Two failure modes, and they are NOT the same problem

### Same key nested = deadlock. No pool size fixes it.

The inner take runs on a **second connection** and waits on the lock the outer frame
holds; the outer frame waits on the inner to return. Circular wait, and no pool size
fixes it — a pool of 1000 just parks 1000 connections.

**What you will actually see depends on the library version**, and it matters for
diagnosis:

- **Before nestjs-sql 11.9.2**, nothing bounded the inner `SELECT pg_advisory_lock(...)`.
  Each execution parked two slots **permanently** and never returned. Signature: ancient
  locks held by idle connections, ack rate 0.
- **From 11.9.2**, `lock_timeout` bounds that wait, so the inner take fails with `55P03`
  after the acquire timeout. The bug is unchanged and every execution still fails — but the
  signature is now **recurring timeout-and-retry churn with young lock ages**, not an
  indefinite hang. Look for the retry rate, not for old locks.

Real case: `createFromOrderMission` wrapped `this.delete(id)` in
``lockBuilder(`mission:${id}`)`` and `delete` takes that same key itself. Byte-identical,
nested. Reached on ordinary traffic (a log_order deleted or cancelled while its mission
exists). Introduced by a copy-paste onto a call that already locked.

- [IN-873](https://linear.app/trusk/issue/IN-873) — closed, shipped in order-mission 1.54.1
- [order-mission#252](https://github.com/trusk-official/order-mission/pull/252)

### Different keys nested = capacity. Sizing fixes it.

Both locks *can* coexist given enough connections. The rule:

> **pool ≥ prefetchCount × nesting depth**

order-mission's AMQP handlers take `orderMission:<id>`, then `createFromOrderMission`
takes `mission:<id>` — depth 2 — with `prefetchCount: 5` in `app.module.ts`. So five
concurrent messages occupy the whole default pool of 5 with their *outer* lock alone, and
the inner one asks for a sixth connection that does not exist.

The failure then feeds itself: job fails → retried (**up to 100×**) → each retry asks for
a lock again. **A full restart does not clear it** — measured in staging, the pool climbed
back to 10/10 within five minutes of a `rollout restart` and stayed pinned, with no test
running. See [`metastable-staging.md`](./metastable-staging.md).

Proven in both directions in staging (2026-08-24): at pool 5, permanent saturation; pool
raised, **0 saturation errors over 1078 log lines**.

- [IN-871](https://linear.app/trusk/issue/IN-871)
- [order-mission#256](https://github.com/trusk-official/order-mission/pull/256) — sets
  `POSTGRES_LOCK_POOL_MAX=15` in staging/preprod/production charts

## Never hold a lock slot across a network call

10 slots cluster-wide (2 pods × 5) × a 10 s HTTP call inside the critical section = **one
locked operation per second**, whatever the pool size. The lock's capacity becomes hostage
to a third party's latency.

The rule that actually works:

> Inside the lock, only local state transitions. Every remote **read** is hoisted and
> re-validated. Every remote **write** moves out.

You cannot blanket-hoist. Two cases:

- **Remote read feeding the serialized decision.** Hoisting it raw creates a TOCTOU. Hoist
  + re-validate under the lock, falling back to a fetch only on mismatch. Reference
  implementation: `mission.service.update`'s `prefetchAvailability` — it carries the id the
  fetch was made for, so the critical section can tell whether the prefetch still matches
  the locked row.
- **Remote write.** It can never be atomic with the DB write anyway; the lock gives an
  illusion of atomicity it cannot deliver. Move it out, with idempotency or compensation.

Still outstanding as of 2026-08-25: `upsertTruskOrder` makes **3 outbound calls under
`orderMission:<id>`** (centiro `getOrder`, trusk-api, interop `getContract`), and
`createFromOrderMission` calls `getCustomerId` there too.
[IN-878](https://linear.app/trusk/issue/IN-878) covers the same defect in
`mission-reset.reset()`.

## Known lock sites worth auditing

- `trusk-api/assignation.js:162-170` calls `syncAssignedOrder(...)` **without
  `await`/`return`**, so the lock releases before the guarded work starts. One-word fix,
  verified in source, not yet ticketed.
- centiro ADR-002 documents an already-fixed defective key as accepted design — misleading
  to a future reader.

## Library helpers

`withEntityLock` / `tryEntityLock` (nestjs-sql 11.10.0,
[trusk-lib#886](https://github.com/trusk-official/trusk-lib/pull/886)) take the lock on the
caller's `EntityManager` via `opts.manager` — one connection instead of two. Prefer them
when the guarded work is already inside a transaction.

## Diagnosing

```sql
-- who holds advisory locks, and for how long
select a.application_name, a.state, count(*),
       max(round(extract(epoch from now() - a.state_change))) oldest_s
  from pg_locks l join pg_stat_activity a using(pid)
 where l.locktype = 'advisory'
 group by 1, 2 order by 3 desc;
```

`<service>-locks` pinned at its max = saturated. Young ages (a few seconds) mean churn, not
a stuck lock — that is the retry storm, not a deadlock. Old ages on an `idle` connection
mean a genuine hang.
