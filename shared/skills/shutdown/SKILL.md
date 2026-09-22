---
name: shutdown
description: "Close the herdr pane hosting an agent, once that agent finishes what it is doing. Use when asked to shut down, close or clean up this pane or another agent's pane when its work is done. Closes a terminal pane only — never the machine. Requires HERDR_ENV=1."
---

# shutdown

Closes a herdr pane after the agent in it stops working. This is a **terminal
pane**, not the host: nothing here powers anything off.

```bash
herdr-shutdown                 # this pane, when I finish the current turn
herdr-shutdown reviewer        # a live agent by name
herdr-shutdown w3:p2           # a pane by id
herdr-shutdown w3:p2 --timeout-min 90
```

It returns immediately and leaves a watcher behind, so it is safe to call as the
last thing you do — including on your own pane, where the wait only resolves
once your turn ends.

## Before calling it

Confirm with the user first when the target is **not** the calling pane. Closing
a pane kills the agent process in it; unsaved work in that pane is gone, and a
closed pane id is never reused.

Say which pane you are closing. `herdr agent list` names the live agents if the
user gave you something ambiguous.

## What it does

Waits for `idle` or `done` — the two states meaning "ready for input", which is
the closest thing herdr has to "finished" — then issues `herdr pane close`.

It gives up after 30 minutes by default and leaves the pane alone. It also
leaves it alone if the agent or pane disappears while waiting: only a clean
idle/done closes anything.

## Limits

- `blocked` is not `idle`. An agent waiting on an approval prompt keeps the
  watcher waiting too, until the budget runs out.
- "Finished" means whatever herdr classifies as `idle`/`done`, which is read
  from the screen. Measured against a 25s shell command, it closed at ~20s — so
  the pane can go while a long tool call is still running.
- Closing the last pane in a tab closes the tab, and the last tab closes the
  workspace. Check `herdr pane list --workspace "$HERDR_WORKSPACE_ID"` if that
  matters.
- Requires `HERDR_ENV=1`; it refuses to run outside herdr.
