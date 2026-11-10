---
name: trains
description: French train prices (OUIGO, TGV INOUI) via mcp__trains__*. Use for a train price, the cheapest day, when to book, or a price alert.
metadata: {"hermes":{"emoji":"🚆","os":["linux"]}}
---

# Trains

Tools: `mcp__trains__train_prices`, `mcp__trains__train_calendar` (start with it when
dates are flexible).

- Sources are unofficial: say so if a price drives a purchase. Never claim to book.
- `price: null` = sold out, never "free". `errors` = a source is down: give the other
  source's prices and name the missing one.
- Prices rise with seat fill and rarely fall: a low fare means book now.
- Alert ("tell me under X €"): create a native cron job that calls `train_prices` and
  messages only when the best price is at or under X; delete it once booked.
