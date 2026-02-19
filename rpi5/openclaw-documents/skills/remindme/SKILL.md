---
name: remindme
description: "⏰ simple Telegram reminders for OpenClaw. cron, zero dependencies."
tags: [cron, reminders, productivity, schedule, telegram]
metadata:
  openclaw:
    summary: "**Remind Me v2:** Schedule reminders anywhere. Natural language, native cron, zero dependencies."
    emoji: "bell"
user-invocable: true
command-dispatch: prompt
---

# Remind Me v2

Set reminders on **any channel** using natural language. No setup. No dependencies.

## Usage

```
/remindme drink water in 10 minutes
/remindme standup tomorrow at 9am
/remindme call mom next monday at 6pm
/remindme in 2 hours turn off oven
/remindme check deployment in 30s
/remindme every day at 9am standup
/remindme every friday at 5pm week recap
/remindme list
/remindme cancel <jobId>
```

## Agent Instructions

When the user triggers `/remindme`, determine the intent:

- **list** → call `cron.list` and show active reminder jobs.
- **cancel / delete / remove `<jobId>`** → call `cron.remove` with that jobId.
- **everything else** → create a new reminder (steps below).

---

### Step 1: Parse the Input (Structured Pipeline)

Extract three things: **WHAT** (the message), **WHEN** (the time), **RECURRENCE** (one-shot or recurring).

Follow this decision tree **in order** — stop at the first match:

#### Layer 1: Pattern Matching

**Relative durations** — look for `in <number> <unit>`:
| Pattern | Duration |
|---|---|
| `in Ns`, `in N seconds`, `in N sec` | N seconds |
| `in Nm`, `in N min`, `in N minutes` | N minutes |
| `in Nh`, `in N hours`, `in N hr` | N hours |
| `in Nd`, `in N days` | N * 24 hours |
| `in Nw`, `in N weeks` | N * 7 days |

**Absolute clock times** — look for `at <time>`:
| Pattern | Meaning |
|---|---|
| `at HH:MM`, `at H:MMam/pm` | Today at that time (or tomorrow if past) |
| `at Ham/pm`, `at HH` | Today at that hour |

**Named days**:
| Pattern | Meaning |
|---|---|
| `tomorrow` | Next calendar day, default 9am |
| `tonight` | Today at 8pm (or now+1h if past 8pm) |
| `next monday..sunday` | The coming occurrence of that weekday, default 9am |
| `on <day>` | Same as `next <day>` |

**Recurring** — look for `every <pattern>`:
| Pattern | Cron/Interval |
|---|---|
| `every Nm/Nh/Nd` | `kind: "every"`, `everyMs: N * unit_ms` |
| `every day at <time>` | `kind: "cron"`, `expr: "M H * * *"` |
| `every <weekday> at <time>` | `kind: "cron"`, `expr: "M H * * DOW"` |
| `every weekday at <time>` | `kind: "cron"`, `expr: "M H * * 1-5"` |
| `every weekend at <time>` | `kind: "cron"`, `expr: "M H * * 0,6"` |
| `every hour` | `kind: "every"`, `everyMs: 3600000` |

#### Layer 2: Slang & Shorthand

| Phrase | Resolves to |
|---|---|
| `in a bit`, `in a minute`, `shortly` | 30 minutes |
| `in a while` | 1 hour |
| `later`, `later today` | 3 hours |
| `end of day`, `eod` | Today 5pm |
| `morning` | 9am |
| `afternoon` | 2pm |
| `evening` | 6pm |
| `tonight` | 8pm |
| `noon` | 12pm |

#### Layer 3: Event-Relative & Holidays

Use your knowledge to resolve holiday/event-relative phrases. If unsure, ask the user to confirm.

#### Layer 4: Ambiguity — Ask, Don't Guess

If you still can't determine WHEN, ask the user. Never silently pick a default time.

---

### Step 2: Compute the Schedule

**Timezone rule:** ALWAYS use the user's local timezone (`Europe/Paris` for this instance). Never default to UTC.

**One-shot** → ISO 8601 timestamp with the user's local timezone offset.
- If the computed time is in the past, bump to the next occurrence.

**Recurring (cron)** → 5-field cron expression with `tz` set to `Europe/Paris`.
- `every day at 9am` → `expr: "0 9 * * *"`
- `every monday at 8:30am` → `expr: "30 8 * * 1"`

**Recurring (interval)** → `kind: "every"` with `everyMs` in milliseconds.

### Validation Checkpoint

Before calling `cron.add`, verify:
1. The computed timestamp is in the future.
2. Duration makes sense (no `everyMs: 0`).
3. Echo back the parsed time in the confirmation so the user can catch errors.

---

### Step 3: Detect the Delivery Channel

Priority order:
1. Explicit override ("on telegram" in message) → use that channel
2. Current channel (Telegram) → deliver there
3. `channel: "last"` → last external channel used

---

### Step 4: Call `cron.add`

**One-shot reminder:**

```json
{
  "name": "Reminder: <short description>",
  "schedule": {
    "kind": "at",
    "at": "<ISO 8601 timestamp>"
  },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "REMINDER: <the user's reminder message>. Deliver this reminder to the user now."
  },
  "delivery": {
    "mode": "announce",
    "channel": "<detected channel>",
    "to": "<detected target>",
    "bestEffort": true
  },
  "deleteAfterRun": true
}
```

**Recurring reminder:**

```json
{
  "name": "Recurring: <short description>",
  "schedule": {
    "kind": "cron",
    "expr": "<cron expression>",
    "tz": "Europe/Paris"
  },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "RECURRING REMINDER: <the user's reminder message>. Deliver this reminder to the user now."
  },
  "delivery": {
    "mode": "announce",
    "channel": "<detected channel>",
    "to": "<detected target>",
    "bestEffort": true
  }
}
```

**Fixed-interval recurring:**

```json
{
  "name": "Recurring: <short description>",
  "schedule": {
    "kind": "every",
    "everyMs": 3600000
  },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "RECURRING REMINDER: <the user's reminder message>. Deliver this reminder to the user now."
  },
  "delivery": {
    "mode": "announce",
    "channel": "last",
    "bestEffort": true
  }
}
```

### Step 5: Confirm to User

After `cron.add` succeeds, reply with:

```
Reminder set!
"<reminder message>"
<friendly time description> (<ISO timestamp or cron expression>)
Will deliver to: <channel>
Job ID: <jobId> (use "/remindme cancel <jobId>" to remove)
```

---

## Rules

1. **ALWAYS use `deleteAfterRun: true`** for one-shot reminders. Omit for recurring.
2. **ALWAYS use `delivery.mode: "announce"`** — without this, the user never sees the reminder.
3. **ALWAYS use `sessionTarget: "isolated"`** — reminders run in their own session.
4. **ALWAYS use `wakeMode: "now"`** — ensures immediate delivery at the scheduled time.
5. **ALWAYS use `delivery.bestEffort: true`** — prevents job failure on transient delivery issues.
6. **NEVER use `act:wait` or loops** for delays longer than 1 minute.
7. **Always use `Europe/Paris` timezone** unless the user specifies another.
8. **Always return the jobId** so the user can cancel later.

## Troubleshooting

- **Reminder didn't fire?** → `cron.list` to check. Verify gateway was running at the scheduled time.
- **Too many old jobs?** → `/remindme list` then cancel old ones.
- **Recurring job keeps delaying?** → After consecutive failures, cron applies exponential backoff (30s → 1m → 5m → 15m → 60m). Backoff resets after a successful run.
