# Authorization rollout (TEC-301) — testing and raising `*_backend_authz`

Triggers are in the index row. What this note answers: how to prove a service's `@AuthRules`
before its enforcement flag goes up, how to read what the guard answers, and which callers will be
refused for reasons no route declaration can fix.

## The flag is the rollback

Every service reads `<name>_backend_authz` (`backendAuthzFlag('<name>')` +
`enforcementFromFlag`). Lowered, the guard computes its decision, logs `auth.enforcement.bypassed`
and lets the request through — so the inventory of real callers comes from the logs before anyone
is refused. `forRoot()` **with no resolver enforces from the first request**: shipping the rules is
then the cutover, with nothing to lower. On `master` (2026-09-22) fleet and communications were in
that state, and interop-configuration, interop-engine, rating and trusk-estimator-api imported the
module bare — no guard at all. `backoffice/.artifact-rights/guard_audit.py` re-measures it from git.

`nestjs-authentication` 12.x has no `DEFAULT_ACCESS`: a route declaring neither `@AuthRules` nor
`@Public()` is **refused** (`src/index.ts` says so). Harmless while the flag is down, fatal the moment it goes up — grep for
undeclared routes before raising anything.

## Reading the answer

| code | message | means |
| --- | --- | --- |
| 401 | `Unauthorized` | no token, unreadable token, **or the service cannot verify** (no `/etc/trusk-auth` mount) |
| 403 | `Missing required permissions: <right>` | a user without the right |
| 403 | `Endpoint restricted to services: a, b, …` | a machine whose `sub` is not in `services:` |
| 403 | (population) | a user token on a machine-only route, or the reverse |

**A 401 on a token you know is valid = the key is not mounted**, not a missing right. That is how
interop-engine and trusk-estimator-api showed up: every legitimate caller refused.

`services:` compares the token `sub` — the caller's `TRUSK_AUTH_ISSUER`, i.e. its **chart alias** —
by strict equality. communications signs `communications-engine` for its outgoing calls, not
`communications`. The back-office never belongs in `services:`: it signs a *user* token and goes
through `permissions`.

## Who can actually sign

Three conditions, all needed (details: `prod-vs-staging-prerequisites.md`, prérequis 4):

1. `trusk-auth` mounted;
2. chart trusk-app ≥ 0.15.0 — the only thing that sets `TRUSK_AUTH_ISSUER`;
3. the generated client used for the call carries the interceptor
   (`Symbol.for('trusk.auth.tokenProvider')` — `grep -rl "trusk.auth.tokenProvider" node_modules/@trusk-official/api-*`).

Plus one that no caller can fix: **gateway strips `authorization`** in its forwarder
(`headersToRemove`), so anything reaching a service through it arrives unsigned — Quivr webhooks,
`/transport/push`. `services: ['gateway']` is dead code until the forwarder changes.

Measured 2026-09-22 on `pr-tec296` pods, from the env and not the charts: roundtrip, fleet,
centiro-orders-api, communications (×3 aliases) sign; IAM, state-status, interop-configuration,
interop-engine, trusk-estimator-api verify only.

## The probe protocol

Kept in `backoffice/.artifact-rights/` (untracked): `build.py` → `rows.json` (the spec, 283
routes), `plan.py` → `authz-plan.json`, `authz-probe.js` (the prober), `authz-cycle.sh` (one
service: raise on `flagd-preview`, confirm, probe, restore), `progress.py` → the dev/tested columns
of the spec artifact.

- **One route per distinct rule**, not per route: 283 routes → 54 rules. Two routes carrying the
  same rule cannot behave differently.
- **The identity matrix is derived from the rule**: anonymous, unreadable token, user with the
  rights, user with *another* right (chosen outside the route's own — a harness that "withholds"
  the very right under test reports a false pass), machine on a human route and the reverse, a
  machine outside the list.
- **The verdict is refused / not refused**, never a status code: 422 on an empty body or 404 on a
  made-up id both prove the caller got past the guard. Path parameters become `tec301-probe`.
- A service token forged in a pod carries **that pod's** `sub`. From a pod that is itself in the
  list, the "outside the list" case is impossible — label it, do not count it. Probe from a pod
  that signs (see above). A pod that cannot sign says so at boot:
  `[trusk-auth] no issuer name (set TRUSK_AUTH_ISSUER or …), service tokens disabled`.
- Before each probe, confirm the flag **on the single remaining pod** over OFREP
  (`preview-environments.md`, "Before probing"). Skipping this produced 3 fake-failing services.

Raising a flag on `flagd-preview` touches only the pods that read it — check with
`kubectl get deploy -A -o json | … openfeature.dev/featureflagsource` before claiming "preview
only". Staging's store (`flagd`) must read the same before and after; the cycle asserts it.

Allowed identities get past the guard, so the probe's representatives **really execute** — among
them `DELETE /status/` (state-status) and `DELETE /missions/:id` (order-mission). One more reason it
runs on a preview and nowhere else.

## Before raising a flag in staging

A week of `auth.enforcement.bypassed` with every flag down first: the `services:` lists were built
from code searches, and the probe runs alone already turned up a missed caller
(`communications-engine`, absent from four lists). The order of the cutover and every
production flip are a human's call.
