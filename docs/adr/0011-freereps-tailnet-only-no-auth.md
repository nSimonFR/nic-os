# 0011 — FreeReps stays unauthenticated, tailnet-only

**Date:** 2026-11-02 · **Status:** Accepted

## Context

FreeReps (Apple Health data) has two identity modes: tsnet (Tailscale WhoIs) or a
built-in dev identity with no credential. tsnet binds the tailnet IP itself, which
rules out socket activation and costs ~120–200 MB permanently. It runs with tsnet
off, so it has no authentication.

## Decision

Accept that. The tailnet is the boundary: it's served only on the tailnet
(:3960), never through Funnel.

## Consequences

- Any tailnet device, and any process on the Pi, including agents, can read the
  health data.
- Funneling it, or sharing the Pi's node, requires revisiting this first.
