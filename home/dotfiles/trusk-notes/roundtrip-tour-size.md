# IN-871 — why `POST /roundtrips/routific` timed out, end to end

Case study, 2026-08. Worth reading whole: the answer was four layers deep, and each layer
looked like the root cause until it was fixed and the symptom stayed.

Reported by ops on 2026-08-11: tours sent from the Ordo hit `408 request_timeout`, the Ordo
retries ×3, and the tour gets created **twice** — two drivers receive the same tour.
[Slack thread](https://trusk.slack.com/archives/CD24UNGJF/p1786434413326909) ·
[IN-871](https://linear.app/trusk/issue/IN-871)

Always tours >20 points, but not all of them.

## The chain

`POST /roundtrips/routific` fans out **one `PUT /missions/:id` per point**. So tour size ×
per-write latency ÷ fan-out concurrency, against a 10 s server timeout:

```
(N / concurrency) × L < 10 s
```

Four things were wrong, in the order they were found and fixed:

1. **Unbounded fan-out.** `Promise.all(points.map(...))` — a 100-point tour opened 100
   concurrent writes. Bounded to 5 via `mapWithConcurrency`
   ([roundtrip#174](https://github.com/trusk-official/roundtrip/pull/174),
   [IN-877](https://linear.app/trusk/issue/IN-877)). Note the worker pool **preserves input
   order** — callers index into the result for the driver and for Onfleet date offsets.

2. **Lock-pool starvation** turning the load into a self-sustaining storm. See
   [`advisory-locks.md`](./advisory-locks.md) and
   [order-mission#256](https://github.com/trusk-official/order-mission/pull/256).

3. **A cache stampede in the interop client.** `InteropConfigurationApiClient` *was*
   already a cache, but `haveToResync()` went true for every concurrent caller at once and
   each launched its own full multi-page reload. 148 `GET /shipment-sites?limit=500` in
   five minutes, 59 % of them timing out. Fixed with single-flight + serve-stale + atomic
   swap ([order-mission#257](https://github.com/trusk-official/order-mission/pull/257)).
   The atomic swap also fixed a **correctness** bug: the old code reset the array to `[]`
   before page 1 and grew it, so a concurrent reader could see a partial snapshot and
   conclude a site that exists is missing.

4. **The one that actually mattered.** `mission.service.getShipmentSite` made its *own*
   `ShipmentSiteFindAll` call, bypassing that cache entirely — and `findOne` calls it while
   building the response to **every write**. Measured at **4.2–8.9 s for a single row** on
   an idle system. Fixed by serving it from the in-memory snapshot, with a live fallback on
   a miss ([order-mission#258](https://github.com/trusk-official/order-mission/pull/258)).

## The numbers

| version | single `PUT /missions/:id` | 100-point tour |
|---|---|---|
| 1.54.6 | 7.98 s | 408 |
| 1.54.7 (stampede fixed) | 9.23 s | 408 |
| **1.54.8** (snapshot) | **1.77 s** | **5.3 s** ✅ |

Final validation: sizes 30→100, disjoint mission sets, run **both ascending and
descending** — 16/16 pass, per-point latency flat at 38–115 ms (i.e. linear at last).

## Two traps worth remembering

**Fixing a layer can look like no progress.** #257 was real and measured (interop 408s
6 % → 1 %, `limit=500` calls halved) yet moved the end-to-end number not at all, because it
did not touch the call site on the hot path. Always re-measure the *end* metric, and when
it does not move, look for a second call site rather than assuming the fix failed.

**Non-monotonic results mean warm-up, not capacity.** The first run after deploy failed at
30–70 but *passed* at 80 and 90. If it were capacity the big tours would fail first. Re-run
in reverse order to separate size from position — descending gave 16/16, proving it was a
post-restart window (most likely AMQP redelivery), not a limit.

## Where the real slowness lives — still open

interop-configuration is **not** slow because of data or CPU:

- `COUNT(*)` on `shipment_site` (1412 rows): 0.06 s
- `COUNT(DISTINCT)` with the full `LEFT JOIN contract_pricing_zone`: **0.28 s**
- pods at **7 % of their CPU limit**; health endpoint 0.5 s

Yet the endpoint takes 4–9 s. That is waiting, not work. `interop_configuration` held **18
PG connections, 12 of them in `ClientRead`** — consistent with the default TypeORM pool of
10 across two pods, but **not verified**. Unticketed.

## Still open on this thread

- **Bound the retries.** 100 attempts on a *404* is an amplifier, not a retry policy. It is
  what converts a transient spike into a permanent regime, and it still produces ~594
  redundant 404 calls to interop every 3 minutes. Unticketed — arguably the last real
  defect.
- **[IN-875](https://linear.app/trusk/issue/IN-875)** — idempotency, deliberately unfixed.
  Confirmed live: a 100-point tour was fully created *after* the client received its 408.
  `rxjs timeout()` does not abort the promise, so the work continues past the response.
- **Network calls still inside AMQP critical sections** — see
  [`advisory-locks.md`](./advisory-locks.md).
- **Boot fragility**: an order-mission pod crash-looped once because interop answered 408
  during the boot cache load. `onModuleInit` fails loudly by design (a cold cache has
  nothing to serve), but #258 widened the projection, making that load heavier. A few
  retries at boot would fix it. Unticketed.
