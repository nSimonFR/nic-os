---
name: populartimes
description: Check Google Maps popular-times busyness for a specific place by Place ID.
version: 1.0.0
metadata:
  hermes:
    tags: [google-maps, places, popularity, busy-times]
    category: productivity
    requires_toolsets: [terminal]
    requires:
      bins: [populartimes-query, goplaces]
      env: [GOOGLE_PLACES_API_KEY]
---

# Popular Times

Use the `populartimes-query` CLI to retrieve weekly popular-times data and
current popularity for a Google Place ID.

## Find a place

Resolve a user-provided name/address with Google Places, then use the returned
`id`/Place ID:

```bash
goplaces resolve "Cafe de Flore, Paris" --json
```

If the result is ambiguous, show the candidate names and addresses and ask the
user which one they mean. Do not guess a place ID.

## Query

```bash
populartimes-query ChIJ...
```

Use `--json` when you need to inspect or transform the full response. Summarize
the current popularity and the busiest hours for the requested day; if no day is
specified, give a short weekly overview. The hourly values are relative
popularity estimates (0–100), not visitor counts. Missing data means Google did
not provide popularity for that place.

## Requirements and limitations

- `GOOGLE_PLACES_API_KEY` must be present in Hermes' environment. If it is
  missing, ask Nico to add a Google Places API key to the encrypted
  `/run/agenix/agent-env` source; never ask them to paste it into chat or commit
  it to the repository.
- Google Maps behavior can change and this unofficial library may stop working.
- Follow Google Maps Platform terms and current billing/quota rules. Do not
  batch-scrape areas or repeatedly poll; query only the place the user asked for.
- Popular-times values are estimates. State that clearly when making
  recommendations based on them.
