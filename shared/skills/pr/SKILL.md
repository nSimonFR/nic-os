---
name: pr
description: Open a Trusk pull request from the current branch and babysit it — write the commits and body to the repo's conventions, push, create the PR, then watch CI and the merge gates until they settle and report the verdict. Use when asked to "open a PR", "faire une PR", "push this and watch CI", or to track an existing PR's checks to completion. Trusk repos only; hand off to /ship to merge and deploy.
---

# /pr — open a Trusk PR, watch it to a verdict

The half before `/ship`: branch → PR → green gate. Reports when the PR is mergeable (or
why it isn't); it does **not** merge.

Conventions live in `~/MyDocuments/TRUSK/CLAUDE.md`; CI failure patterns in
`notes/merge-and-ci-traps.md`. **Prefix every git/gh with `unset GH_TOKEN &&`** — the
ambient token can't see `trusk-official` and yields bogus 404s.

Args: nothing (current repo + branch), or a PR number/URL to just watch from step 3.

## 1. Before creating anything

- Not on `master`; branch off it if so. Read the full diff and say what it does.
- **Commits are what release** — `Type(Scope): desc`, scope from
  `Feature|Fix|Docs|Style|Refactor|Test|Chore`. `Feature`/`Refactor` → minor, rest →
  patch, `Perf:` → **no release at all**. No Linear prefix in the message: repos are
  rebase-only, so each commit lands verbatim and semantic-release parses messages, never
  the PR title.
- Changed a return type? Grep its test stubs by hand — `strictNullChecks` is off, so
  `tsc` passes on things e2e catches.
- Brace every `if` body. Repo may have a `.github/pull_request_template.md` — use it.

## 2. Create it

```bash
unset GH_TOKEN
git push -u origin <branch>
gh pr create --repo trusk-official/<repo> --title "Type(Scope): desc" --body-file -
```

- Put `Closes IN-XXX` / `Fixes TEC-XXX` at the **top of the body** — that is what wires
  Linear; the title and branch name do nothing. Keep the title clean anyway.
- Body: what changed and why, how it was verified, anything the reviewer must know
  (migration, flag, breaking payload). Not a diff restatement.
- Add `need client API` only if another repo must consume a not-yet-merged route — and
  remember the workflow fires on **push**, not on `labeled`, so push an empty commit after
  labelling (`notes/client-libs-and-renovate.md`).
- Draft PRs still run CI.

## 3. Watch the checks

Three jobs come from the reusable workflow — `Check runner availability`, `Trusk CI`
(eslint/prettier + full jest e2e on a docker-compose PG + Docker build), and
`Security & Quality Scans` (Trivy/npm-audit, comments on the PR). The **only required
status check is `CI Gate`**, and its ruleset has no bypass actors — `--admin` will not
merge past a red gate, so the gate has to actually go green.

Wait with `Monitor`, never a foreground poll:

```
Monitor: until [ "$(unset GH_TOKEN; gh run view <ID> --repo trusk-official/<repo> --json status --jq .status)" = completed ]; do sleep 30; done \
  && unset GH_TOKEN && gh pr checks <n> --repo trusk-official/<repo>
```

Match the run by **headSha** — its display name is often `CI Workflow` or the PR title.
Pushing a fix starts a new run; re-resolve the id rather than reusing the old one.

## 4. Triage red

```bash
gh run view <id> --repo trusk-official/<repo> --log-failed \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -aE "✕|● |Tests:|error TS|prettier|Expected|Received"
```

Then decide, and say which one it is:

- **Your diff** → fix, commit in the same convention, push, back to step 3.
- **Environmental** → suites that bootstrap Nest can't run locally (`POSTGRES_URL must be
  a string`); prove it with the same failure count on `origin/master`.
- **Flake** → hook timeouts on suites hitting real third-party APIs, stale
  `node_modules` changing outcomes. One `gh run rerun --failed`, and report that you did.
  Two reruns without a hypothesis is not triage — escalate instead.

`notes/merge-and-ci-traps.md` has each of these with its signature.

## 5. Report when it lands

Once `CI Gate` is `success` and the PR is mergeable, report in one block:

- PR number + URL, title, target branch;
- the commits as they will land, and the release each one implies (minor/patch/none);
- check results, including anything the security scan commented;
- remaining gates: required reviews, conflicts, `mergeable`/`mergeStateStatus` from
  `gh pr view --json`;
- what merging will trigger — release, image, and whether a `trusk-applications` bump is
  needed after it.

Then offer `/ship` to merge and deploy. If it never goes green, report the failure and
what you ruled out; don't leave it hanging.
