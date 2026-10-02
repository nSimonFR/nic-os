---
name: airbnb-pricing
description: Suggest Airbnb nightly prices for the Zen flat (Paris 20e) from its calendar, the 90-night cap and the pricing rules. Use for the airbnb-pricing cron job, or when asked in the group to change a price rule, a base price or the season dates.
metadata: {"hermes":{"emoji":"🏠","os":["linux"]}}
---

# Airbnb pricing — Zen 2-Room Flat

Suggest-only: Airbnb has no host API, so a human applies every price in the app.
Never claim a price was changed.

## Inputs

The cron job's **Script Output** is the JSON from `hermes-airbnb-pricing`:

- `triggers` — why you were woken: `weekly_summary`, `new_booking a→b`,
  `cancelled a→b`, `urgent_gap <date> (Nn, J-x)`, `season_over`, `forced`.
- `cap` — Paris 90-night cap for a primary residence, per calendar year.
  `binding: true` means more open nights than the cap allows.
- `gaps` — every run of open nights until `season_end`, with `prices` (runs of
  nights at one € list price, and `net` after the 18.6 % host fee) and
  `bookable_at_min_stay`.
- `months` — sellable vs booked nights and occupancy.
- `mismatch` — nights booked on one source but not the other.

Rules live in `rules.json` next to this file. The script already applied them;
your job is judgement and the message, not re-deriving the arithmetic.

## How to reason

1. **Is the cap binding?** If yes, a night sold cheap now is a night lost later —
   hold prices, never go below `floor.cap_binding`. If not, an unsold night is
   simply lost — follow the lead-time ladder down to `floor.cap_free`.
2. **Pace.** A month at ≥ 80 % occupancy more than 3 weeks out is underpriced:
   suggest +5–10 % on its remaining nights. A month under 40 % with less than
   2 weeks to go: let the ladder work, don't add extra cuts.
3. **Orphan gaps** (`bookable_at_min_stay: false`): suggest a 1-night minimum
   on those dates only, at the premium price given. Say it costs an extra
   turnover; skip the suggestion if it falls between two same-day turnovers.
4. You may adjust a script price by at most ±10 %, and must say why. Never
   below the applicable floor.
5. `mismatch` non-empty → mention it once: a confirmation email may be missing
   from PERSO, or a booking was cancelled.

## Message (French, Telegram, short)

Weekly (`weekly_summary`):

```
🏠 Airbnb Zen — semaine du <date>
Plafond : <used>/90 nuits · <remaining> restantes · <open> ouvertes (<tendu|pas tendu>)
Taux d'occupation : oct. 71 % · nov. 18 % · déc. 0 %

À régler dans l'app :
• 11–12 oct. (2 n, J-9) → 122 €/nuit (net 99 €)
• …
```

Urgent / booking change: one line of context (`Nouvelle résa 14–17 nov.`,
`Trou J-5`), then only the prices that change.

Group: nSimon, ServaTilis, Alfie. No preamble, no sign-off, no markdown tables.
If the triggers need no price change, reply exactly `[SILENT]`.

`season_over`: one message saying the season is over (date or cap reached) and
that the cron job can be removed: `hermes cron remove <id>`.

## Changing a rule

When asked in the group (e.g. "passe novembre à 145"), edit `rules.json`, then
confirm the new value. Base prices are per `YYYY-MM`. The file is versioned in
nic-os (`hosts/rpi5/hermes/skills/airbnb-pricing/rules.json`) and the next
deploy overwrites a live edit — say so, and ask nSimon to commit it.

## Hand run

```bash
~/.hermes/scripts/airbnb-pricing.sh --no-state --force   # facts JSON, state untouched
```
