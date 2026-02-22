# Heartbeat Checklist

## Trigger Policy (authoritative)

Run heartbeat **only** when one of these is true:

1. A scheduled heartbeat trigger fires (every 30 minutes), or
2. Nico explicitly asks for heartbeat (`heartbeat`, `run heartbeat`, `status check`, etc.).

Do **not** run heartbeat automatically on normal incoming messages.

### De-duplication guard

If a heartbeat was completed less than 25 minutes ago, skip duplicate automatic runs.
Exception: always allow explicit/manual heartbeat requests.

## Heartbeat Actions

- 🏥 Check system health (failed services, resource usage)
- 📢 Review any pending notifications
- 🌤️ Check weather for location (currently: Paris)
- 📊 Check usage and costs (context %, token usage, session costs)
- 💾 Update memory with important recent events

## Weather Location

Current: **Paris** 🇫🇷

To change: `Set heartbeat weather location to <city>`

Examples: London 🇬🇧 | Berlin 🇩🇪 | Lyon 🇫🇷
