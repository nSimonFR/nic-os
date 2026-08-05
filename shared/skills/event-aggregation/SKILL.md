---
name: event-aggregation
description: "Use when aggregating external events into scheduled digests."
version: 1.0.0
---

# Event Aggregation Services

## Trigger

Use for a reusable service that discovers upcoming events across websites, stores prior state, detects meaningful changes, and delivers a scheduled digest.

## Architecture

Keep extraction separate from event lifecycle management:

1. Load a source registry (`sources.json` or equivalent).
2. Try discovery mechanisms in order: public JSON/API, RSS/Atom, ICS, HTML.
3. Make source-specific selectors, JSON paths, regexes, pagination links, detail-page links, and defaults **configuration**, not application code.
4. Normalize every record into one schema before persistence.
5. Persist normalized events and content hashes.
6. Compare snapshots for new, updated, cancelled, and removed events.
7. Deduplicate after normalization using stable identifiers, then a fallback key such as canonical title + start + venue.
8. Render only material changes into a compact delivery format.

Parsers extract; the normalizer, change detector, persistence, and notifier remain generic.

## Source Investigation

Before coding a source, probe every likely public surface independently and retain the working endpoint:

- WordPress REST types/endpoints (`/wp-json/wp/v2/types`, custom post types)
- store/product endpoints
- RSS/Atom feeds
- sitemap and event-page discovery
- ICS exports
- homepage/listing HTML and detail pages

Do not assume the documented or conventional API route is enabled. A public WordPress product endpoint may work even if the WooCommerce Store API does not.

## Config-Driven Extraction

Support declarative extraction rules for JSON fields. A source may need to derive `start_at`, capacity, or availability from title/description text, while the parser stays unchanged.

Useful configuration concepts:

- `fields`: canonical field → JSON dot path
- `extract`: canonical field → input field(s), capture regex, output template
- `defaults`: source-wide venue/city/timezone values
- `required_fields`: discard records that are not events (for example, require a derived `start_at`)
- `methods`: ordered extraction fallbacks

Use stable upstream numeric/product/event IDs as `external_id` whenever available. Otherwise derive an ID from canonical URL and start time.

## Dates and Filtering

- Parse source-local dates with the source timezone.
- Convert to ISO 8601 before comparisons.
- Ignore past events only after date parsing.
- Never treat undated products/content as events merely because they came from a shop event listing.
- For recurring/calendar-driven sources, treat ICS dates as authoritative when available.

## Reliability and State

- Process sources independently; one failure must not block the digest.
- On a source failure, retain that source's prior snapshot rather than marking all its events removed.
- Exclude cosmetic content changes from `content_hash`; track only user-meaningful fields: timing, venue, registration URL, price, capacity, registration/remaining seats, and status.
- First run establishes a baseline. Do not send a flood of pre-existing events unless explicitly requested.

## Verification

Before enabling a scheduler:

1. Add a regression test for any newly discovered extraction pattern.
2. Run the full test suite.
3. Run live against every configured source with structured logs.
4. Confirm expected counts and inspect a sample event for each source.
5. Run a second time against the same state: it must report no changes.
6. Create/rebuild the production baseline only after the live result is correct.

## Delivery

Keep Telegram output compact: title, date/time, venue, price, seats, and link. Only mention source errors in operational logs unless the user asks for diagnostics.

See `references/wordpress-product-events.md` for a verified WordPress product-feed investigation pattern.
