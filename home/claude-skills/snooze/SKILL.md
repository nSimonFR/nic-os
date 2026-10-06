---
name: snooze
description: Snooze this T3 Code thread until a given time, so it leaves the active list and comes back then. Use when the user says /snooze, "snooze this until …", "remind me about this tomorrow", or "park this".
---

# /snooze <when>

1. Turn `<when>` into an absolute ISO-8601 time in the user's local zone (`date`
   first): "2h" → now + 2h; "tomorrow" → tomorrow 09:00; "monday" → next Monday
   09:00. No argument → tomorrow 09:00. Must be in the future.
2. Call `t3_thread_organize` with `{"action": "snooze", "snoozedUntil": "<iso>"}`, no
   `threadId` (it targets this thread). This works mid-turn.
3. Reply with one line: snoozed until `<local time>`. End the turn — any later
   activity on the thread brings it straight back.

No `t3_*` MCP tools means this session is not in T3 Code: say it cannot be snoozed.
