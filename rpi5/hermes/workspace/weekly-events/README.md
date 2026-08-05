# Weekly Events

Configuration-driven tabletop-event aggregator. It reads `sources.json`, normalizes events, persists a SQLite snapshot, detects changes, and optionally sends a compact Telegram digest.

## Run

The Hermes deployment seeds this directory to `/home/nsimon/.hermes/workspace/weekly-events`.

```bash
cd /home/nsimon/.hermes/workspace/weekly-events
PYTHONPATH=. python3 -m weekly_events.app --config sources.json --state data/events.sqlite3
# Send the digest to the current configured Telegram chat (uses the agenix bot token)
PYTHONPATH=. python3 -m weekly_events.app --send
```

The first run establishes the baseline. Run it once without `--send`; subsequent runs report only changes. Failed sources retain their previous snapshot so they never generate false removals.

## Components

- `weekly_events/app.py` — scheduler entrypoint/orchestrator, structured logs
- `weekly_events/parsers.py` — generic JSON/API, ICS, and regex-configured HTML parser
- `weekly_events/ics.py` — iCalendar parser
- `weekly_events/normalize.py` — canonical event model, stable IDs, content hashes
- `weekly_events/store.py` — SQLite persistence
- `weekly_events/changes.py` — new/updated/cancelled/removed detection
- `weekly_events/notify.py` — compact Telegram Markdown
- `sources.json` — all source-specific rules

## Source configuration

Each source declares a priority-ordered `methods` list: `json`, `rss`, `ics`, `html`. The first producing events wins. JSON uses `url`, `items_path`, and `fields` (dot paths). HTML uses an `event_pattern` to segment the page plus `field_patterns` capture regexes. Add a site by adding an entry only; application code is unchanged.

Required event fields are normalized to: `source_id`, `external_id`, `title`, `games`, `description`, `start_at`, `end_at`, `timezone`, `venue`, `city`, `organizer`, `price`, `capacity`, `registered`, `remaining_seats`, `registration_url`, `event_url`, `calendar_url`, `status`, `content_hash`.

Stable source IDs are preferred. When missing, the normalizer derives one from canonical URL + start date. Hashes exclude cosmetic whitespace.

## Initial source notes

- Robin des Jeux: Store API is currently 404, so its configured fallback needs a live product/listing endpoint when the site exposes one.
- Au Bonheur des Jeux: current WordPress MEC endpoint returns historical records without dates; it needs its individual ICS endpoint linked into its source configuration to yield authoritative upcoming occurrences.
- Magic Corporation Animation: live homepage HTML extraction is operational, including stable tournament IDs, registration URLs, price, capacity, registered count, and remaining seats. Its event-page ICS URL is stored as `calendar_url`.

## Scheduler

Use the Hermes job created for this project, or any scheduler:

```cron
0 9 * * 1 cd /home/nsimon/.hermes/workspace/weekly-events && PYTHONPATH=. python3 -m weekly_events.app --send >> data/weekly-events.log 2>&1
```

## Tests

```bash
PYTHONPATH=. python3 -m unittest discover -s tests -v
```

Tests cover normalization/hash stability, ICS parsing/cancellation, persistence, change detection, and digest rendering.
