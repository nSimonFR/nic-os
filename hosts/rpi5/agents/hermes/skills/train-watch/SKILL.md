---
name: train-watch
description: Check French train prices (OUIGO and TGV INOUI) and set price alerts. Use when asked for the price of a train, the cheapest day, or to be told when a fare drops or falls under a budget.
metadata: {"hermes":{"emoji":"🚆","os":["linux"]}}
---

# Train watch

MCP tools `mcp__trains__*` read live prices; alerts are watches managed with
`~/.hermes/scripts/train-watch.sh <cmd>` (prints JSON) and re-priced by its cron
job. Prices are 2nd class, 1 adult, per train. Sources are unofficial (OUIGO's web
API, TGV INOUI via 12train.com): say so if a price will drive a purchase, and never
claim to have booked anything.

## Tools

- `train_prices(origin, destination, date)` — every train of the day, both sources.
- `train_calendar(origin, destination, start, end)` — OUIGO lowest fare per day, one
  call. Use it first when the user's dates are flexible.

## Watches

```
train-watch.sh add Paris Brest 2026-12-20 --max-price 80 [--drop-pct 10] [--after 08:00]
               [--before 18:00] [--max-changes 0] [--sources ouigo,inoui] [--note TEXT]
train-watch.sh list [--all]    train-watch.sh remove ID    train-watch.sh history ID
```

`--max-price` alerts at or under it; `--drop-pct` alerts on a fall since the previous
check; neither means `--drop-pct 10`. The same route/date/window again updates it.

## Behaviour

- Cities are names: `Paris`, `Brest`, `Paris Montparnasse`. Paris means all stations.
- Direct trains only unless `max_changes` says otherwise. `price: null` = sold out or
  no 2nd-class fare — never quote it as free.
- The cron job re-prices every watch and sends the alert itself; after `add` just
  confirm the rule in one line, don't promise a time.
- A round trip is two watches (outbound date, return date, swapped cities).
- History is one point per check, so "should I wait?" rests on days of data, not on
  one snapshot. With no history say so; prices rise with seat fill, rarely fall.

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
