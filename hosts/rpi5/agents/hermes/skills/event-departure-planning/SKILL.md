---
name: event-departure-planning
description: Use when planning departure for the next calendar event.
metadata: {"hermes":{"emoji":"🚲","requires":{"bins":["python3"]}}}
---

# Event Departure Planning

Use this workflow for prompts such as: “pour mon prochain événement, à quelle heure dois-je partir ?” Read the personal calendar live, identify the next relevant event and its location, calculate a realistic departure plan, then state the answer concisely.

## Default transport rule

- Default to **bicycle**.
- If the event is explicitly with **Alfie**, default to **metro / public transport**.
- If the attendee or transport mode is unclear and that choice materially changes the plan, ask one concise question before estimating.
- If the event has no usable location, ask for it. Do not invent one.

## Workflow

1. **Get current time** with `date` and query the personal Nextcloud calendar live using `caldav-calendar`.
   - For “next event”, inspect today and the following days until a timed event with a location is found.
   - Use the current residence: 52 boulevard Arago, 75013 Paris through the end of October 2026; otherwise 82 rue Alexandre Dumas, Paris.
   - Completion: event name, start time, location, and origin are known.

2. **Get a route estimate.**
   - Bicycle: use `~/.hermes/skills/productivity/maps/scripts/maps_client.py distance ORIGIN --to DESTINATION --mode cycling`.
   - Metro/public transport: use a current route source (prefer official RATP/Île-de-France Mobilités; web search is acceptable if official routing is unavailable). Capture walking legs, expected wait/connection time, and final walk.
   - The local Maps skill does not provide public-transit routing; never label a car/walk result as metro.
   - Completion: report the route duration and its components/assumptions.

3. **Build the departure time.**
   - Include **5 minutes to get downstairs / leave the building** unless the user says otherwise.
   - Add a practical arrival margin by default: **15 minutes** for ordinary appointments; **20 minutes** for cinema, station/airport, first-time locations, or events where punctuality matters.
   - Add a modest transport contingency: at least **5 minutes** for cycling; for metro, include a realistic wait/connection allowance and add **5–10 minutes** beyond the nominal route when live disruption data is unavailable.
   - Calculate `event start − (downstairs + route + contingency + arrival margin)` using Python; do not mental-calculate.
   - Completion: a clock time is produced and is before the event.

4. **Answer in this compact format:**
   ```
   **[Event] — [start time]**
   Mode: [bike / metro]
   Trajet estimé : ~[N min] ([brief components]).
   Marge incluse : [downstairs + contingency + arrival buffer].
   **Pars vers [HH:MM].**
   ```
   Mention that estimates without live traffic/disruption data may vary. Do not create or modify calendar events.

## Common Pitfalls

- Do not reuse a stale calendar result: read the calendar in the current turn.
- Do not assume a permanent home address; apply the date rule.
- Do not treat OSRM cycling as live traffic or transit data.
- Do not silently choose metro when the user did not mention Alfie; bicycle is the default.
- Do not omit the travel duration or the included margin.

## Verification Checklist

- [ ] Calendar was read live.
- [ ] Event location and start time are explicit.
- [ ] Correct origin for the date was used.
- [ ] Mode follows the bicycle/Alfie/clarification rule.
- [ ] Departure calculation includes 5 minutes downstairs and a buffer.
- [ ] Reply includes both route time and departure time.
