# Routing notes

## Live-event calculation

```bash
# Current local time
 date '+%Y-%m-%d %H:%M %Z'

# Nextcloud personal calendar, narrow range
python3 ~/.hermes/skills/caldav-calendar/scripts/nc-cal.py \
  list --calendar personal --from YYYY-MM-DD --to YYYY-MM-DD --json

# Driving/walking/cycling baseline (maps skill is under productivity/maps)
python3 ~/.hermes/skills/productivity/maps/scripts/maps_client.py \
  distance '<origin>' --to '<destination>' --mode cycling
```

## Geocoding fallback

Venue brands may not geocode reliably. Retry with the street address (or a nearby address in the event data), then check the returned display name before using it.

## Departure formula

`leave = event start − desired arrival buffer − route duration − 5 minutes building exit − contingency`

Follow the main skill: event-specific arrival requirement, otherwise 15 minutes
for ordinary appointments or 20 minutes for timing-critical events; contingency
is at least 5 minutes. OSRM is a non-live road-route baseline, not a transit
itinerary. Use an actual cycling-capable endpoint and check the returned mode.
