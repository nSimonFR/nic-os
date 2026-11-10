---
name: trains
description: Check French train prices (OUIGO and TGV INOUI) for a day or a date range. Use when asked for the price of a train, the cheapest day, or when to book.
metadata: {"hermes":{"emoji":"🚆","os":["linux"]}}
---

# Trains

MCP tools `mcp__trains__*`. Prices are 2nd class, 1 adult, per train. Sources are
unofficial (OUIGO's web API, TGV INOUI via 12train.com): say so if a price will
drive a purchase, and never claim to have booked anything.

- `train_prices(origin, destination, date)` — every train of the day, both sources.
- `train_calendar(origin, destination, start, end)` — OUIGO lowest fare per day, one
  call (max 62 days). Use it first when the user's dates are flexible.

## Alerts

No stored watch: for "tell me when it drops under X", create a native Hermes cron
job whose prompt calls `train_prices` and sends a message only when the best price
is at or under X (otherwise reply with nothing). Delete the job once the user books.

## Behaviour

- Cities are names: `Paris`, `Brest`, `Paris Montparnasse`. Paris means all stations.
- Direct trains only unless `max_changes` says otherwise. `price: null` = sold out or
  no 2nd-class fare — never quote it as free.
- A round trip is two lookups (outbound date, return date, swapped cities).
- There is no price history. OUIGO prices rise with seat fill and rarely fall, so
  when a fare is already low, say booking now beats waiting.

## Message (French, short)

```
🚆 Paris → Brest · 20/12
OUIGO 06:46 → 10:34 : 75 €  ← meilleur
TGV INOUI 08:43 → 12:44 : 120 €
```

## Traps

- A source can be down (`errors` in the result). Report the other source's prices
  and name the missing one; don't conclude "no train".
- OUIGO prices exclude bags and seat choice.
