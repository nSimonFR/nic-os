# Merge and CI traps

Triggers: `gh pr merge` refused · "can't be rebased" · CI red but local green ·
`mockResolvedValue(null)` · peer-dep resolution failure · `-pr.` version pins ·
`The job was not started because recent account payments have failed` · a job failed with 0 steps ·
push lands but no CI run appears · `no checks reported on the '<branch>' branch` · `CONFLICTING DIRTY` ·
merge cut no release / no image · `git stash pop` brought back unrelated changes.

## Billing block: `The job was not started because recent account payments have failed`

Org-level GitHub Actions billing, not your code. GitHub-hosted jobs (`ubuntu-latest`) are refused
with **0 steps** and no log (`/logs` → `BlobNotFound`). Self-hosted jobs still run, so `Trusk CI` can
be green while the required `CI Gate` fails through `Security & Quality Scans`. The reason is only in
the annotations:

```bash
gh api "repos/trusk-official/<repo>/actions/runs/<id>/jobs" --jq '.jobs[]|select(.conclusion=="failure")|.id' |
  while read -r j; do gh api repos/trusk-official/<repo>/check-runs/$j/annotations --jq '.[].message'; done
```

It also stops **releases**: `Check runner availability` is GitHub-hosted and gates `Trusk CD` and the
image build. Seen 2026-09-25: merges cut no version (roundtrip, state-status), and order-mission got
its `1.74.0` tag but no image. `gh run rerun --failed` hits the same block until someone with billing
access fixes Settings → Billing & plans. Afterwards, rerun the failed runs (failed ones rerun correctly,
skipped ones do not) and assert the image tag before any trusk-applications bump.

## A PR with conflicts runs no CI

GitHub does not fire `pull_request` workflows on a PR it cannot merge. The push lands, the PR head
moves, and `gh pr checks` says `no checks reported`. Check `gh pr view <n> --json mergeable` →
`CONFLICTING`, then rebase.

Recurring cause: semantic-release rewrites `truskInitContainers[].image` in
`deployment/charts/default.yaml` on every release, so a PR touching those lines (renaming the init
container, changing its command) conflicts after each release. Resolve by keeping your change and
**master's image tag**. A rebase force-push also dismisses existing approvals (`REVIEW_REQUIRED`).

## Merge methods differ per repo

Squash is disabled on several (order-mission, trusk-applications). **backoffice allows rebase
only** → a branch carrying a merge commit is unmergeable there.

```bash
gh api repos/trusk-official/<repo> \
  --jq '{squash:.allow_squash_merge, merge:.allow_merge_commit, rebase:.allow_rebase_merge}'
```

Linearize a branch that has a merge commit:

```bash
git reset --soft origin/master && git commit
git push --force-with-lease
```

Check `git rev-parse HEAD^{tree}` before and after — you must merge the tree CI validated.

## `strictNullChecks` is off

`null` is assignable to everything, so `tsc --noEmit` passes on code that breaks at runtime.
Case 2026-08-24: return type changed `Foo | null` → `Foo[]`, a test stub kept
`mockResolvedValue(null)`, tsc clean, CI caught it as a runtime 500 in e2e.

**Changing a return type → grep its test stubs by hand.** Do not force `--strictNullChecks`
on an ad-hoc tsc run; it floods you with pre-existing errors that are artefacts of your flag.

## Suites that bootstrap the Nest app cannot run locally

They need the docker-compose Postgres → `POSTGRES_URL must be a string`. On order-mission,
7 of 29 suites. Normal, not a regression. Prove it:

```bash
git stash push -u -q -m jest-ab && { npx jest 2>&1 | grep -cE '^FAIL'; git stash pop -q; }
```

Same count on `origin/master` = environmental.

**Never run `git stash pop` unless your own push succeeded.** With nothing to stash, `git stash`
creates no entry, and the pop applies whatever is on top of the list. That list is **shared by every
worktree of the repo**, so the pop can bring back someone else's months-old stash. Seen 2026-09-25:
`pre-IN-614 local edits` was popped into a roundtrip worktree (conflict in `tsconfig.build.json`).
Chain with `&&` as above. To test old code, prefer `git worktree add --detach <tmp> HEAD` with
`node_modules` symlinked in. If a pop lands anyway, `git restore --staged --worktree --source=HEAD
<files>` (git keeps the entry after a conflicted pop), then delete the rerere entry the conflict
recorded under `$(git rev-parse --git-common-dir)/rr-cache/`.

## Peer-pinning across `@trusk-official/nestjs-*`

Every `nestjs-*` peer-pins `nestjs-core` at an **exact** version → cannot bump one alone.
`@latest` does not resolve it; pin every version explicitly in one `npm install`. Local npm
10.x is more permissive than CI's 11.x — a local install that succeeds can still fail CI.

## Prerelease pins rot

PRs labelled `need client API` publish `<ver>-pr.<PR#>.<run>.<attempt>` clients, then get
merged and forgotten. Still on master 2026-08-25:

| repo | pin | latest |
| --- | --- | --- |
| order-mission | `api-order-mission-client` `1.28.0-pr.160.526.1` | 1.54.8 |
| roundtrip | `api-order-mission-client` `1.16.0-pr.102.256.1` | 1.54.8 |
| mobile-app-gateway | `api-communications-query` `^1.33.2-pr.154.335.1` | 1.49.3 |

```bash
git show origin/master:package.json | grep -oE '"@trusk-official/[a-z-]+": "[^"]*pr\.[^"]*"'
```

## e2e suites that call real external APIs flake on jest's 5 s hook timeout

`service-onfleet`'s `tests/scenarii/*` drive the **real** Onfleet API. Their hooks chain several
sequential HTTP calls — `driver.js`'s `afterAll` does up to four `tasks.get` / `forceComplete` /
`deleteOne`. Jest's default 5 s applies to hooks too, and it is not enough.

Symptom, on diffs touching none of those code paths:

```
● Test suite failed to run
  thrown: "Exceeded timeout of 5000 ms for a hook."
  at beforeAll (tests/scenarii/task.js:14:5)
```

Hit twice in two days (2026-09-15 `driver.js` `afterAll`, 2026-09-16 `task.js` `beforeAll`), both
times green on a plain `gh run rerun --failed` with zero code change. **A rerun proves it is the
budget, not your diff** — but do the A/B before blaming the flake: `git stash` and run the suite on
the pristine branch, identical failures = environmental.

`driver.js` had raised only its own `beforeAll` to 10 s; the other five files had nothing. Fixed
2026-09-16 with `jest.setTimeout(30000)` in `tests/scenarii/suite.test.js` — file-scoped, so unit
and integration suites keep the 5 s default. Apply the same pattern to any suite that talks to a
third-party API rather than raising the global `testTimeout`.

## Stale node_modules silently change test outcomes

Same repo, same day: 2 integration tests failed locally and passed in CI. Cause was neither —
the installed `@trusk-official/api-order-mission-client` predated `ASSISTANCE_SECOND_CREW`, so
`OrderTypeEnum.ASSISTANCE_SECOND_CREW` was `undefined`, a fixture wrote `mission_type: null` and
the sort took a different branch. `package.json` pinned `1.45.0`; node_modules had older.

```bash
npm install --no-save --no-package-lock @trusk-official/<client>@<pinned>   # no lockfile churn
```

Reflex when a test disagrees with CI: check the **installed** version of any enum/const you rely
on, not the pin.

## e2e dies on `Failed to connect before the deadline` after adding feature flags

The message comes from `@grpc/grpc-js`: `FeatureFlagsModule` installs a gRPC flagd provider, and the
docker-compose test stack has Postgres and RabbitMQ but no flagd sidecar. Every suite that boots the
real `AppModule` then waits out the connect deadline and reads as "the app never came up". Seen on
trusk-estimator-api and communications (TEC-301). Fix in the test env only — deployed envs must keep
resolving from flagd:

```bash
printf '\nFF_DISABLED=true\n' >> tests/test.env     # the library's own escape hatch
```

## A vendored chart tarball silently drops every value

`deployment/charts/charts/trusk-app-<v>.tgz` committed next to a `Chart.yaml` asking for another
version: helm no longer resolves the **aliased** dependency, the `<service>:` values are ignored, and
the Deployment renders with trusk-app's defaults — the pod pulls **`nginx:1.0.0`** and
`ImagePullBackOff`s while ArgoCD says `Synced`. rating, 2026-09-22 (tgz 0.14.1, Chart.yaml 0.15.0).
No other service vendors: delete the tarball, ArgoCD fetches the dependency. Check before pushing:

```bash
cd deployment/charts && helm dependency build >/dev/null && \
  helm template <svc> . -f default.yaml -f preview.yaml | grep -E '^\s+image:'
```

The broken Deployment then refuses the fix: its selector (`name: trusk-app`) differs from the real one
and a selector is immutable — `field is immutable` on sync. Delete that Deployment (preview only) and
sync again. Staging is safe if its selector did not change between chart versions; compare both with
`helm template` before assuming.

## zsh does not word-split unquoted variables

`for x in $LIST`, `set -- $pair`, `K="kubectl …"; $K scale …` all silently misbehave. Iterate
explicitly. Never suppress stderr while debugging — a `>/dev/null 2>&1` on a silently-failing
`$K scale` cost real time.

Two more that bit on 2026-09-22: `for a in $apps` over a newline-separated `kubectl … -o name`
iterated **once** ("0 apps synced"), and `npx prettier --write $files` passed the whole list as a
single argument, failed, and the `&&` chain after it reported the *next* step as broken. Use
`… | while read -r x; do …; done`.

**A probe that fails must not print a negative.** `kubectl get secret X -o jsonpath='{.data}' |
python3 -c 'json.load(…)'` printed "absent" because `json.load` choked on the output — and a secret
that exists in `staging` was declared missing there, then removed from a staging chart. Test
existence by exit code: `kubectl get secret X >/dev/null 2>&1 && echo present || echo absent`.
