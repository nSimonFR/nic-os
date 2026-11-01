---
name: price-watch
description: Use when adding or changing price-watch products and alert conditions.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [prices, shopping, alerts, sqlite, cron]
    related_skills: [scheduled-digest-automation, notification-digests]
---

# Price Watch

## Overview

Maintain the daily price detector through its declarative product catalogue and SQLite observation history. The configuration defines what to watch and the SQL store records every verified or unverified observation; never put price history back into JSON.

## When to Use

Use this skill when the user asks to:

- add or remove a watched product;
- add or change an alert threshold or relative-discount condition;
- inspect historical prices or explain an alert;
- change the detector schedule or reporting requirements.

Do not use it for a one-off price lookup that should not be persisted.

## Paths

Resolve `${HERMES_HOME:-$HOME/.hermes}` at runtime.

- Catalogue: `$HERMES_HOME/workspace/price-watch/products.json`
- CLI: `$HERMES_HOME/workspace/price-watch/price_watch.py`
- SQL database: `$HERMES_HOME/workspace/price-watch/prices.sqlite3`
- Cron job: `10687cfd14ed`

The database is runtime state and must not be committed. The catalogue, CLI, tests, and this skill are versioned in `nic-os`.

## Add a Product or Condition

1. Read `products.json` and choose a stable lowercase slug. Do not rename an existing slug unless migrating its SQL history.
2. Add the product with `name`, `category`, `currency`, `sources`, and `conditions`. Preserve comparison dimensions in metadata for variants such as capacity, cosmetic condition, battery option, screen type, or screen size.
3. Conditions use one of these supported forms:

```json
{"kind":"threshold","metric":"total_price","operator":"<=","value":1850}
```

```json
{"kind":"relative_drop","metric":"total_price","operator":">=","value":10,"baseline":"previous_comparable_price"}
```

4. Synchronize configuration into SQL:

```bash
python3 "$HERMES_HOME/workspace/price-watch/price_watch.py" sync
```

5. Confirm the product and conditions exist:

```bash
python3 "$HERMES_HOME/workspace/price-watch/price_watch.py" products
sqlite3 "$HERMES_HOME/workspace/price-watch/prices.sqlite3" \
  "SELECT product_slug,kind,operator,threshold FROM alert_conditions ORDER BY product_slug,id;"
```

6. Run the tests in the source checkout. Completion means the full suite passes and the cron prompt references this skill and SQL CLI.

## Record a Price

Record every checked offer, including non-alerting prices, so comparisons reflect actual previous prices:

```bash
python3 "$HERMES_HOME/workspace/price-watch/price_watch.py" record \
  --product valerion_visionmaster_pro_2 \
  --price 1799 --shipping 0 \
  --seller 'Valerion Europe' \
  --url 'https://example.invalid/direct-offer' \
  --variant 'projector-only' \
  --details '{"coupon":"AUTUMN200","delivery_france":true}'
```

The command emits JSON containing `alert`, previous comparable price, and real savings. Use `--unverified` when a page or checkout cannot be verified: the observation remains auditable but cannot alert or establish a best price.

For a Back Market phone, the variant key must include capacity, cosmetic condition, and battery option. For Valerion bundles it must distinguish projector-only, PureVision/white, and Fresnel ALR plus screen size.

## Inspect History

```bash
python3 "$HERMES_HOME/workspace/price-watch/price_watch.py" history \
  --product backmarket_iphone_15_pro_128 --limit 20
```

Or query SQL directly:

```sql
SELECT observed_at,total_price,seller,variant_key,url,verified
FROM price_observations
WHERE product_slug = 'backmarket_iphone_15_pro_128'
ORDER BY observed_at DESC;
```

## Alert Discipline

- Price means TTC plus delivery to France when known.
- Verify coupons or cart reductions before treating them as real.
- Never use a crossed-out MSRP as historical evidence.
- Compare like-for-like variants only.
- A verified observation is stored even if it does not trigger.
- Silence is correct when no condition matches.
- Alert output must include exact product/variant, current total, previous comparable price, savings in euros and percent, seller, end date when known, direct link, and verdict.

## Common Pitfalls

1. **Editing runtime SQL conditions manually.** `sync` replaces conditions from `products.json`; edit the catalogue first.
2. **Writing observations into the catalogue.** JSON is configuration only; SQL is history.
3. **Comparing unlike variants.** A degraded battery or white screen is not comparable to a premium battery or Fresnel ALR screen.
4. **Recording search snippets as verified prices.** Mark incomplete or stale evidence `--unverified`.
5. **Changing only the live cron.** Persistent Hermes changes must also be versioned in `nic-os`.
6. **Committing `prices.sqlite3`.** It is mutable runtime state and must remain excluded.

## Verification Checklist

- [ ] Product catalogue is valid JSON.
- [ ] `sync` succeeds and SQL contains every configured condition.
- [ ] A non-alerting observation is retained in `price_observations`.
- [ ] A matching test observation triggers and reports prior comparable price.
- [ ] Unverified evidence never alerts.
- [ ] Tests pass.
- [ ] Cron schedule is daily and has this skill attached.
- [ ] Source changes are committed through a `nic-os` PR.
