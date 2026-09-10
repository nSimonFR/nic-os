---
name: calendar-travel-planning
description: "Use for calendar travel times, departures, and backplans."
metadata:
  hermes:
    emoji: "🧭"
---

# Calendar travel planning

Use for questions such as “when should I leave?”, distance/time estimates for a calendar event, or a backward plan for an appointment, show, lesson, or payment deadline.

## Workflow

1. **Get the live date/time** before interpreting “today”, “tonight”, or “tomorrow”.
2. **Read the live calendar event** in a narrow date range. Extract the actual start/end, location, and any event-specific arrival instruction. Do not rely only on chat history.
3. **Resolve the origin** from durable user memory. If the user has a date-dependent address, select the address that applies on the event date. Do not expose a home address unless needed for the requested calculation.
4. **Resolve the destination**:
   - Use the calendar location verbatim first.
   - If venue-name geocoding fails, retry using the street address or a nearby address from the event description.
   - Confirm that the resolved location matches the event city/venue before presenting a route.
5. **Choose the transport mode before routing.** Default to bicycle. For an event explicitly with **Alfie**, default to metro/public transport. If the attendee or mode is unclear and materially changes the plan, ask one concise question. Do not silently turn a driving or walking estimate into a public-transit estimate.
6. **Calculate route estimates** with the `maps` skill for bicycle routes. For metro/public transport, use a current transit source and include walking legs, expected waiting/connections, and final walk. Never invent a metro line, interchange, stop, or duration from a road-route estimate; if an authoritative transit itinerary cannot be obtained, say so and give only a clearly labelled estimate. Treat OSRM as a non-live estimate, never a transit schedule or live ETA.
7. **Work backwards** from the event start. Always include **5 minutes to leave the building**, the route duration, and a contingency of at least 5 minutes. Use the event-specific arrival requirement, otherwise add 15 minutes for ordinary appointments and 20 minutes for cinema, stations/airports, first-time venues, or timing-critical events. Add a preparation buffer only when a full retroplanning is requested.
8. **State limitations clearly**: without live disruption data, say that the estimate may vary.

## Output

Keep it compact: event start/destination, assumed mode and route estimate, recommended leave time with arrival buffer, then one relevant caveat. For a full retroplanning, list anchors backward from the event start (arrival, departure, ready-by, reminder).

## Scheduling reminders

Only create or edit calendar events/reminders after the user explicitly asks. Before writing, query the target date to avoid duplicates and verify the created/edited event by listing it again.

## Reference

See [references/routing-notes.md](references/routing-notes.md) for tool commands and fallback behavior.
