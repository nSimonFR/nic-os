# Staging measurements — verify quiet before measuring

Triggers: about to quote a staging latency/throughput number · restart did not fix it · retry
storm · load test setup or cleanup · "is this a real limit or is the env sick?"

## The trap

A load spike pushes staging into a state that **sustains itself after the trigger is gone**:

```
spike → resource starves → jobs fail → AMQP retries (up to 100×)
      → each retry re-consumes the starved resource → …
```

- **A restart does not clear it.** Measured: order-mission's lock pool back to 10/10 within
  5 min of `rollout restart`, nothing running.
- **It reads exactly like a real capacity limit.** All tour sizes 20→100 returned 408 at
  ~10.3 s — a flat wall. 20 points had passed in 6.56 s an hour earlier on a quiet system.

## Pre-flight, every run

```sql
select a.application_name, count(*) from pg_locks l join pg_stat_activity a using(pid)
 where l.locktype='advisory' group by 1 order by 2 desc;
select count(*) from pg_stat_activity;
```

Run from any pod on the shared instance (`pg_stat_activity` is instance-wide):

```bash
kubectl --context trusk-staging-ts -n staging exec <pod> -c <svc> -- node -e '
const {Client}=require("pg");
const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,
  password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});
(async()=>{await c.connect(); /* ... */ await c.end();})();'
```

- Quiet = **~0 advisory locks held**, connections well under cap.
- Pool at max (`order-mission-locks` 10/10) → **measurement void**, do not proceed.
- **Re-check between runs.** Each run publishes events consumers chew on for minutes.

## Exit a metastable state

**Shed load — scale the consumer *down*.** order-mission 2→5 pods made it worse (44 → 110
saturations/min); 2→1 flipped the success/failure ratio within minutes.

Restart is not an exit. Raising the ceiling often just moves the plateau (pool pinned at
10/10 → pinned at 22/40 when raised) — it removes one failure mode and reveals the next.

## Two diagnostic heuristics

- **A real fix that moves nothing end-to-end** means a second call site, not a failed fix.
  Case: the interop cache-stampede fix cut interop 408s 6 %→1 % and halved `limit=500` calls,
  yet the end metric did not move — because the hot path used a *different*, uncached call
  site. Always re-measure the end metric; when flat, look for another caller.
- **Non-monotonic results mean warm-up, not capacity.** First run after deploy failed at
  30–70 but passed at 80 and 90. Capacity would fail the big ones first. Re-run in reverse
  order to separate size from position — descending gave 16/16.

## Other measurement invalidators

- **Off-hours downscaling**: `downscaling-staging` scales to 0; ArgoCD sync windows deny
  weekdays 20:00–07:00 + all weekend. A service can be both un-synced and scaled to 0.
- **A scaled-down dependency**: scaling `trusk-estimator-api` down put an order-mission
  consumer into a retry storm (246 failures/2 min) that ate every lock slot. Scale back what
  you scale.
- **Other people's traffic**: 8.1 req/s against interop-configuration with no test running.

## Test data

Mark everything (`specificities`/`tags = "<ticket>-loadtest"`). Clean from **each owning
service's pod** — a role reads other schemas but cannot write them (writing `roundtrip.point`
from the order-mission pod → `permission denied`).

Deleting a test tour leaves its missions `WAITING/ROUTED` with no tour. Inherent to the
cleanup; say so rather than leaving silent orphans (166 existed 2026-08-24). Resetting them
properly goes through state-status, not a direct mirror write.

## Related

[`advisory-locks.md`](./advisory-locks.md) — the resource that starves most often.
[IN-884](https://linear.app/trusk/issue/IN-884) — staging PG ran 102-104/100 connections until
[trusk-infra-iac#298](https://github.com/trusk-official/trusk-infra-iac/pull/298) raised
`max_connections` to 200 (static param → **instance restart required**).
