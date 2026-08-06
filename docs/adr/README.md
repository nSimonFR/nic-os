# Architecture Decision Records

Short, immutable notes recording **why** something was chosen — and, more often
in this repo, **why something was removed**.

## Why this directory exists

Every reversal in this repo used to live in exactly two places: a commit message
and the author's head. Neither is reachable by someone (or something) reading the
tree. The result is a recurring failure mode: residue from a retired system keeps
resurfacing — a `.cursor/rules/` file describing a directory two agent
generations gone, a live agent manual pointing at deleted paths, a lockfile read
by nothing, an exported env var for a service deleted a month earlier — and each
sweep has to re-derive the reasoning from `git log` before it dares delete
anything.

An ADR is cheaper than that archaeology.

## When to write one

- A service, module, or dependency is **removed** — say what replaced it, or that
  nothing did.
- Something was **tried and abandoned** — so it isn't re-attempted.
- A non-obvious constraint drove a choice, and the code can only show the choice.

Skip it for ordinary changes. The commit message is enough when the diff explains
itself.

## Format

`NNNN-kebab-case-title.md`, numbered sequentially. Status is one of `Accepted`,
`Superseded by NNNN`, or `Reversed`. Keep them short — a screen at most. Never
rewrite an ADR to reflect a later decision; write a new one and mark the old one
superseded.

## Index

| # | Decision | Date | Status |
|---|---|---|---|
| [0001](0001-openclaw-retired.md) | OpenClaw retired in favour of PicoClaw | 2026-04-20 | Superseded by 0002 |
| [0002](0002-picoclaw-retired.md) | PicoClaw retired, Hermes is the sole agent | 2026-07-24 | Accepted |
| [0003](0003-codex-proxy-removed.md) | codex-proxy replaced by tiny-llm-gate's native provider | 2026-07-15 | Accepted |
| [0004](0004-no-commitlint.md) | No commitlint; Conventional Commits by convention | 2026-08-06 | Accepted |
| [0005](0005-regreet-over-lightdm.md) | ReGreet over LightDM on BeAsT | 2026-08-06 | Accepted |
| [0006](0006-socket-activate-v2-options-dropped.md) | socket-activate v2 placeholder options dropped | 2026-08-06 | Accepted |
| [0007](0007-claude-credentials-owner.md) | The bridge config dir owns account 1's Claude credentials | 2026-08-06 | Accepted |
| [0008](0008-host-capabilities-over-hostnames.md) | Host capabilities over host names; dirs named per host | 2026-08-06 | Accepted |
