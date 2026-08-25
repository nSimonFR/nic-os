# Staging goes metastable — check it is quiet BEFORE trusting any measurement

The single most expensive lesson of IN-871 (2026-08-24): several hours of measurements were
void because the environment was already saturated when the test started, and it looked
exactly like a real capacity limit.

## The shape of it

A transient load spike pushes the system into a state that **sustains itself after the
trigger is gone**:

```
spike → a resource starves → jobs fail → AMQP retries (up to 100×)
      → each retry re-consumes the starved resource → …
```

Two properties make this nasty:

1. **A restart does not fix it.** After a full `rollout restart` of order-mission, the
   advisory-lock pool climbed back to 10/10 within five minutes and stayed pinned, with no
   test running.
2. **It is indistinguishable from a real limit** unless you look at the resource directly.
   Every tour size 20→100 returned 408 at ~10.3 s — a flat wall that reads as "capacity",
   but 20 points had passed in 6.56 s on a quiet system an hour earlier.

## The check, before every run

```sql
-- advisory locks held, by application
select a.application_name, count(*)
  from pg_locks l join pg_stat_activity a using(pid)
 where l.locktype = 'advisory' group by 1 order by 2 desc;

-- total connections against the cap
select count(*) from pg_stat_activity;
```

Run it from any pod on the shared instance (`pg_stat_activity` is instance-wide):

```bash
kubectl --context trusk-staging-ts -n staging exec <pod> -c <svc> -- node -e '
const {Client}=require("pg");
const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,
  password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});
(async()=>{await c.connect(); /* ... */ await c.end();})();'
```

- Quiet baseline: **~0 advisory locks held**, connections well under the cap.
- A service's lock pool at its max (`order-mission-locks` at 10/10) → **the measurement is
  void**. Do not proceed.
- **Re-check between runs.** Your own test seeds the next one: each run publishes events
  that the consumers then chew through for minutes.

## Getting out of it

**Shed load — scale the consumer *down*, not up.** Counter-intuitive but it is the textbook
exit: fewer concurrent retries means the starved resource drains. Scaling order-mission
from 2 to 5 pods made it measurably worse (44 → 110 saturations/min); scaling to 1 flipped
the success/failure ratio within minutes.

Restarting is not an exit. Raising the resource ceiling often just moves the plateau (the
pool went from pinned-at-10 to pinned-at-22 when raised to 40) — it removes one failure
mode and reveals the next.

## Other things that invalidate a staging measurement

- **Off-hours downscaling.** `downscaling-staging` scales deployments to 0 outside working
  hours, and ArgoCD sync windows deny weekday 20:00–07:00 plus all weekend. A service can
  be simultaneously un-synced and scaled to 0.
- **A scaled-down dependency.** Scaling `trusk-estimator-api` down put an order-mission
  AMQP consumer into a retry storm (246 failures / 2 min) that saturated every lock slot.
  Anything you scale, scale back.
- **Whoever else is using staging.** 8 req/s of background traffic against
  interop-configuration was present with no test running at all.

## Test data hygiene

Mark everything (`specificities`/`tags = "<ticket>-loadtest"`) and clean from **each owning
service's pod** — a service's DB role can read other schemas but not write them (writing
`roundtrip.point` from the order-mission pod fails `permission denied`).

Deleting a test tour leaves its missions in `WAITING/ROUTED` with no tour. That is inherent
to the cleanup, not a bug — but say so rather than leaving silent orphans (166 existed as
of 2026-08-24, ~90 of them mine). Resetting them properly means going through state-status,
not writing the mirror directly.

## Related

- [`advisory-locks.md`](./advisory-locks.md) — the resource that starves most often
- [`roundtrip-tour-size.md`](./roundtrip-tour-size.md) — the full IN-871 case study
- [IN-884](https://linear.app/trusk/issue/IN-884) — staging PG ran at 102-104/100
  connections in steady state until
  [trusk-infra-iac#298](https://github.com/trusk-official/trusk-infra-iac/pull/298) raised
  `max_connections` to 200 (static param → **instance restart required**)
