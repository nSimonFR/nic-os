# 0003 — codex-proxy replaced by tiny-llm-gate's native codex provider

**Date:** 2026-07-15 · **Status:** Accepted
**Commits:** `7ecc9fc` *feat(tiny-llm-gate): native codex provider (v0.9.1), drop codex-proxy* ·
`1989849` *chore(rpi5): remove orphaned openai-codex-proxy.nix module*

## Context

`openai-codex-proxy.nix` ran a loopback proxy on `:4040` that the `codex` CLI
authenticated against with a fixed API key, so that `~/.codex/auth.json` held no
`tokens` block. That was a workaround, not a design: whenever the shared OAuth
lineage rotated, a `tokens` block in `auth.json` would silently 401 the proxy and
take the agent down with it.

tiny-llm-gate v0.9.1 gained a native codex provider, making the whole proxy
redundant.

## Decision

Dropped the proxy. The gate speaks to codex directly.

## Consequences

- `:4040` is free. The homepage tile for it was removed in `d0e70bc`.
- The `⚠️ Never run codex login` warning that guarded the workaround no longer
  applies to this path.
- `known_issue_codex_proxy_oauth_rotation` is obsolete.

Residue cleaned up on 2026-08-06: `rpi5/home.nix` still exported
`sessionVariables.CODEX_PROXY_KEY = "codex-proxy-local"` — plus six lines of
warning comment explaining a war that had already ended — for a service deleted a
month earlier. Credential ownership for the native path is a separate concern,
tracked as `known_issue_codex_native_creds_ownership`.
