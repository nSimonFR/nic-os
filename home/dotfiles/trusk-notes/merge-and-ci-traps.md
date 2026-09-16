# Merge and CI traps

Triggers: `gh pr merge` refused · "can't be rebased" · CI red but local green ·
`mockResolvedValue(null)` · peer-dep resolution failure · `-pr.` version pins.

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
git stash -u -q; npx jest 2>&1 | grep -cE '^FAIL'; git stash pop -q
```

Same count on `origin/master` = environmental.

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

## zsh does not word-split unquoted variables

`for x in $LIST`, `set -- $pair`, `K="kubectl …"; $K scale …` all silently misbehave. Iterate
explicitly. Never suppress stderr while debugging — a `>/dev/null 2>&1` on a silently-failing
`$K scale` cost real time.
