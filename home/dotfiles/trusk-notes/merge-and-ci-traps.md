# Merge and CI traps

Small, repeatedly costly. The general rule ("PR CI ≠ local build") is in `../CLAUDE.md`;
these are the specific ways it bites.

## Merge methods differ per repo

`gh pr merge --squash` fails with *"Squash merges are not allowed on this repository"* on
several repos, and **backoffice allows rebase only**. A branch carrying a merge commit is
then unmergeable there — `"This branch can't be rebased"` — and must be linearized first:

```bash
git reset --soft origin/master && git commit   # one commit on top of master
git push --force-with-lease
```

Verify the tree survived the rewrite (`git rev-parse HEAD^{tree}` before and after) so you
merge exactly what CI validated.

Check before assuming:

```bash
gh api repos/trusk-official/<repo> \
  --jq '{squash:.allow_squash_merge, merge:.allow_merge_commit, rebase:.allow_rebase_merge}'
```

## `strictNullChecks` is off — local `tsc` will not save you

These repos set `"strictNullChecks": false`, so `null` is assignable to everything and
`tsc --noEmit` passes on code that breaks at runtime. Real case (2026-08-24): a method's
return type changed from `Foo | null` to `Foo[]`, a test stub kept
`mockResolvedValue(null)`, `tsc` was clean, and CI caught it as a runtime 500 in the e2e
suite.

**When you change a method's return type, grep its test stubs by hand.** Do not force
`--strictNullChecks` on an ad-hoc `tsc` invocation to look for these — it floods you with
hundreds of pre-existing errors that are artefacts of your own flag.

## Local jest cannot run suites that bootstrap the Nest app

Those need the docker-compose Postgres and fail with *"Test suite failed to run …
`POSTGRES_URL` must be a string"*. On order-mission that is 7 of 29 suites. This is normal,
not a regression.

**Prove it rather than assume it** — stash your work and run the same suites on
`origin/master`:

```bash
git stash -u -q
npx jest 2>&1 | grep -cE '^FAIL'
git stash pop -q
```

Identical counts = environmental. Different = yours.

## Peer-pinning across `@trusk-official/nestjs-*`

Every `nestjs-*` package peer-pins `nestjs-core` at an **exact** version, so you cannot bump
one library alone. `@latest` does not resolve it; pin every version explicitly in a single
`npm install`. And local npm (10.x) is more permissive than CI's (11.x) — a local install
that succeeds can still fail CI on peer deps.

## Prerelease pins rot

Service PRs labelled `need client API` publish `<ver>-pr.<PR#>.<run>.<attempt>` clients.
They get merged and then forgotten. As of 2026-08-25, still on master:

- order-mission → `api-order-mission-client` `1.28.0-pr.160.526.1` (latest: 1.54.8)
- roundtrip → `api-order-mission-client` `1.16.0-pr.102.256.1`
- mobile-app-gateway → `api-communications-query` `^1.33.2-pr.154.335.1` (latest: 1.49.3)

`npm ci` depending on a PR prerelease is fragile. Sweep with:

```bash
git show origin/master:package.json | grep -oE '"@trusk-official/[a-z-]+": "[^"]*pr\.[^"]*"'
```

## zsh does not word-split unquoted variables

Bit me four times in one session. `for x in $LIST`, `set -- $pair`, and `K="kubectl …"; $K scale …`
all silently do the wrong thing. Iterate explicitly, and **never** suppress stderr while
debugging — a `>/dev/null 2>&1` on a silently-failing `$K scale` cost real time.
