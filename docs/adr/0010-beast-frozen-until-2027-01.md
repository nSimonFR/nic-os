# 0010 — BeAsT is frozen until January 2027

**Date:** 2026-11-02 · **Status:** Accepted · **Revisit:** 2027-01

## Context

BeAsT has been off since late August 2026 and does not boot. `hosts/beast/` is
still evaluated in CI (`eval BeAsT`), and rpi5 modules still reference it: Immich
ML, `beast-power` (wake), monitoring, the LLM gate.

## Decision

Freeze it rather than remove it. Until 2027-01:

- no feature work in `hosts/beast/`, and agents don't offer it for builds,
  containers, ollama or Immich ML;
- CI keeps evaluating it, so the config doesn't rot against nixpkgs while it's off;
- rpi5's references to it stay as they are.

## Consequences

- A change that breaks `eval BeAsT` is still fixed, minimally.
- In January 2027: bring it back, or remove `hosts/beast/` and the rpi5
  references in one PR and supersede this ADR.
