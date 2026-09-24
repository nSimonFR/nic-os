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

**gateway**: on `master` it strips `authorization` (`headersToRemove`), so everything through it
arrives unsigned. gateway#108 (on #101) replaces that with a **user** token minted from the IAM user
each route names (`iamUserId`): `sub` = that user's email, `perms` = its IAM rights, never a service
token. Consequences: a `kinds: ['service'], services: ['gateway']` rule refuses it ("not open to user
tokens"); the route's IAM user must hold the route's rights (no `expandRights` in #108 — list read
AND write). Validated on pr-tec296 2026-09-24: webhooks pass with gates up; empty the IAM user's
rights → `403 Missing required permissions` after the 60 s cache.

Legacy services sign by hand (auth-tokens 2.x + `transformRequest` / per-call headers, generated
clients frozen when the image's node is older than the client's `engines`): shipment-reader,
service-onfleet, trusk-calendar, trusk-api, front-tracking-page, trusk-cresus (3 workers),
centiro-status-warehouse, centiro-delivery-form, trusk-auto-status, trusk-templates-service
(1 issuer per alias), trusk-api-warehouse, trusk-business. Each was found the same way: a
`401 no-token` in a target's log with the gates up. The artifact's "Qui signe" table is the list.

## Relayed tokens — the chain counts, not the neighbour

Inside a request, nestjs-core relays the **incoming** token on outgoing calls. A service that
enriches its answer by calling a neighbour sends its *caller's* `sub`, so the neighbour's list must
hold whoever opened the chain. Measured: trusk-cresus → order-mission `GET /missions/:id` → fleet
`GET /availability/:id` (403 → OM 503 → no trusker invoice); tracking page → trusk-api → centiro →
state-status `PUT /status`. Two readings, not decided (artifact, « À déterminer ») : call as the
service (`runOutsideRequestContext`, used today only for shared caches in order-mission and centiro)
or extend lists. **Until decided: extend lists**, commented `TEC-301 relay, to settle`.

The refusal log has no caller. Find it from the other side: scan every deployment's log for
`status code 40[13]` over the run window (`for d in $(kubectl get deploy -o name)…`), or match the
refused request's query string to the code that builds it (`select=id,label,type` → fleet).

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

## End-to-end: data-bo + smoke with every gate up

`backoffice/.artifact-rights/final_run.py` (raise all → `workflow-template-data-bo` →
`smoketest-backoffice-template` → refusals per deployment → lower). Before trusting a run:
- **Auth0 dev tenant** (`dev-l6u5nr9zrgvn`) intermittently serves `/u/login/identifier`; the QA
  login page object expects email+password on one page → login fails, everything cascades.
  `curl -sL -o /dev/null -w '%{url_effective}' https://pr-<slug>-bo.trusk.com/auth/login` must end
  in `/u/login`.
- **Wake race**: at 07:00 some pods start before the OpenFeature webhook (`failurePolicy: Ignore`)
  → 1/1 without flagd, OFREP never answers, `up` waits 15 min. Restart the pod.
- **Sleep**: kube-green at 20:00 and the `pr-namespace-shutdown` deadline. A run started after
  ~18:15 is void (run 6).
- 0 guard refusals + mass failure = environment, not authz.

## Before raising a flag in staging

A week of `auth.enforcement.bypassed` with every flag down first: the `services:` lists were built
from code searches, and the probe runs alone already turned up a missed caller
(`communications-engine`, absent from four lists). The order of the cutover and every
production flip are a human's call.
