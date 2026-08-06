# 0004 — No commitlint; Conventional Commits by convention

**Date:** 2026-08-06 · **Status:** Accepted

## Context

`.githooks/commit-msg` shelled out to `pnpm dlx @commitlint/cli --config
commitlint.config.cjs`. That config file did not exist. Neither did
`package.json`. And `core.hooksPath` pointed at `.git/hooks`, not `.githooks`, so
the hook had never once been invoked — it was the repo's only enforcement
mechanism, broken and unreachable, while `README.md` documented installing it in
two separate sections.

Three options were on the table: make it work, delete it, or leave it. Leaving a
documented-but-broken hook is strictly the worst of the three — it advertises a
guarantee the repo does not provide.

## Decision

Deleted the hook and the README sections. Conventional Commits stay a convention.

## Consequences

- No Node/pnpm dependency, and no `pnpm dlx` network fetch on every commit —
  which matters on a 3.9 GB rpi5 that is also the primary dev machine.
- Nothing mechanically rejects a malformed commit message. Acceptable: the repo
  has followed Conventional Commits consistently by hand across its whole
  history, so the hook would have caught nothing.
- `README.md` now states plainly that the convention is unenforced, so nobody
  goes looking for the hook that used to be promised.

If enforcement is ever genuinely wanted, prefer a CI check over a local hook —
it needs no per-clone `git config` step, and it cannot be bypassed with
`--no-verify`. Note that as of 2026-07-15 this repo has no CI at all (garnix is
dead), so that would mean standing up CI first.
