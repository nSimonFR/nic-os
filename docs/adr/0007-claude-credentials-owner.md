# 0007 — The bridge config dir owns account 1's Claude credentials

**Date:** 2026-08-06 · **Status:** Accepted

## Context

Account 1 has two config dirs: `~/.claude`, and the `~/.claude-rc` shadow the
Remote Control bridge needs (it refuses any endpoint but `api.anthropic.com`,
which `~/.claude/settings.json` overrides globally). `prepConfigScript` mirrored
every entry into it as a symlink.

Two comments disagreed about which copy is authoritative:
`claude-remote-control.nix` said `~/.claude`, and pointed the keep-warm extractor
there; `claude-rc-boot-resume.py` said that copy goes stale and read
`~/.claude-rc`. One had to be wrong.

## The measurement

| | `~/.claude` | `~/.claude-rc` |
|---|---|---|
| `accessToken` | `""` (len 0) | 108 chars |
| `expiresAt` | `0` | valid, ~1h out |
| inode | 301532 | 1721937 — a **regular file**, not the installed symlink |

`claude` **replaces** `credentials.json` on refresh (temp + rename) rather than
rewriting it, severing the symlink. The refreshing process — the bridge — keeps
the only live tokens; the other copy is blanked, same JSON shape with empty
strings. So a dead store exists and parses; only a non-empty `accessToken`
distinguishes it. Boot-resume was right.

Live at the time: `claude-oauth-extract.service` failed for 12h, leaving
`/run/claude-oauth/token` (tiny-llm-gate's Anthropic FileBearer credential) 24h
stale; `claude-token-refresh.service` failed on every fire against the blanked
store; and every bridge restart re-linked the live credentials to the blank file.

## Decision

`~/.claude-rc/.credentials.json` owns account 1's tokens. `~/.claude` stays
authoritative for everything else it lends the bridge.

1. `prepConfigScript` seeds rather than links, and only when the bridge copy has
   no usable token.
2. `claude-oauth-keepwarm.nix` takes `credentialsFiles`, an ordered candidate
   list, and resolves the live store per run. Single-dir accounts pass one entry.
3. The refresh timer runs with `CLAUDE_CONFIG_DIR` set to the owning dir.

Declared, but still *resolved* rather than trusted: the divergence comes from an
upstream write strategy we don't control and points either way — a `/login` in a
plain shell writes `~/.claude`. A resolver survives both directions.

## Consequences

Divergence becomes harmless, not impossible; only an in-place upstream rewrite
would fix it properly. Supersedes the
`known_issue_claude_rc_credentials_symlink_divergence` note, which recorded the
symptom while the cause was unknown.
