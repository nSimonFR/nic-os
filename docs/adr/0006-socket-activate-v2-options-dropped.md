# 0006 — socket-activate v2 placeholder options dropped

**Date:** 2026-08-06 · **Status:** Accepted

## Context

`hosts/rpi5/lib/socket-activate.nix` is one of the three real seams in this repo: 13
uniform callers, zero escape hatches. Two parts of its interface had no users at
all:

- **`warmupSchedule`** — an `OnCalendar` string for "predictable pre-warm curls",
  explicitly documented as `RESERVED for v2 — not yet implemented; option name
  claimed so v2 stays backwards-compatible with v1 configs`. It read nothing and
  emitted nothing.
- **`workers.<unit>.policy = "keepAwake"`** — the module emits nothing for a
  `keepAwake` worker, i.e. the branch is definitionally a no-op. All five workers
  across `sure`, `karakeep` (×2), `gramps-web` and `showmycards` use `sleepWith`.

## Decision

Both removed. `policy` is now `enum [ "sleepWith" ]`.

Considered and rejected: keeping `warmupSchedule` on the strength of its
`RESERVED` comment. Reserving an option name only buys backwards compatibility if
someone *set* it — and nobody can have, because setting it did nothing. A v2 that
wants the option can add it then, with the semantics it actually needs, rather
than inheriting a name chosen before the feature was designed.

## Consequences

- The module's interface now describes only behaviour it implements. An option
  that silently does nothing is worse than a missing one: it invites a caller to
  set it and believe something happened.
- `policy` being a unary enum is deliberate and is the honest description of the
  module today. Keep it as an enum rather than dropping the option — the second
  policy is a plausible near-term need (cron-like schedulers such as Celery beat,
  where a missed tick is unacceptable, genuinely do want their lifecycle left
  alone), and an enum leaves room to re-add one without a breaking change.
- If `keepAwake` comes back, it should come back as an emitted behaviour with a
  caller, not as a documented no-op.
