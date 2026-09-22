---
name: pr
description: Open a Trusk pull request from the current branch and babysit it — write the commits and body to the repo's conventions, push, create the PR, then watch CI and the merge gates until they settle and report the verdict. Use when asked to "open a PR", "faire une PR", "push this and watch CI", or to track an existing PR's checks to completion. Trusk repos only; hand off to /ship to merge and deploy.
---

# /pr — open a Trusk PR, watch it to a verdict

The half before `/ship`: branch → PR → green gate. Reports when the PR is mergeable, or why
it isn't. Does **not** merge.

Conventions in `~/MyDocuments/TRUSK/CLAUDE.md`, CI failures in
`notes/merge-and-ci-traps.md`. **Prefix every git/gh with `unset GH_TOKEN &&`.**

Args: nothing (current repo + branch), or a PR number/URL to watch from step 3.

## 1. Before creating

Not on `master`. Read the full diff and say what it does.

**Commits are what release** — `Type(Scope): desc`, scope from
`Feature|Fix|Docs|Style|Refactor|Test|Chore`; `Feature`/`Refactor` → minor, rest → patch,
`Perf:` → **nothing**. No Linear prefix: repos are rebase-only, so each commit lands verbatim
and semantic-release parses messages, never the title. Changed a return type? Grep its test
stubs by hand — `strictNullChecks` is off, so `tsc` passes where e2e won't.

## 2. Create

```bash
unset GH_TOKEN && git push -u origin <branch>
gh pr create --repo trusk-official/<repo> --title "Type(Scope): desc" --body-file -
```

`Closes IN-XXX` goes at the **top of the body** — that is what wires Linear; the title and
branch do nothing. Body: what changed, how it was verified, what the reviewer must know
(migration, flag, breaking payload). Use the repo's template if it has one. Add
`need client API` only if another repo consumes a not-yet-merged route — and push an empty
commit after labelling, the workflow fires on push, not on `labeled`.

## 3. Watch

Three jobs: `Check runner availability`, `Trusk CI` (lint + full jest e2e on a compose PG +
Docker build), `Security & Quality Scans` (comments on the PR). The **only required check is
`CI Gate`**, whose ruleset has no bypass actors — `--admin` won't merge past it.

```
Monitor: until [ "$(unset GH_TOKEN; gh run view <ID> --repo trusk-official/<repo> --json status --jq .status)" = completed ]; do sleep 30; done \
  && unset GH_TOKEN && gh pr checks <n> --repo trusk-official/<repo>
```

Match the run by **headSha** — its name is often `CI Workflow`. A pushed fix starts a new
run; re-resolve the id.

## 3b. The branch image, and the gate bypass

A green run pushes **one image per branch** to GAR — that's what a preview env consumes
(`/trusk-preview-deploy`). The tag is the branch sanitized by `sed "s/[^a-z0-9_.]/_/ig"`, so
`feat/coa-postpone` → `feat_coa_postpone` (`/` and `-` both become `_`). Push Image runs
after the checks, so a red run means no image. Renovate branches are skipped unless labelled
**`push-image`** — mention it when the PR is one and someone wants to deploy it.

```bash
unset http_proxy https_proxy
gcloud artifacts docker tags list \
  europe-west1-docker.pkg.dev/trusk-tools-tpfqef/trusk-registry/<svc> \
  --format="value(tag)" | grep -x '<sanitized>'
```

**`bypass-ci-gate`** on the PR makes `CI Gate` pass over a red CI. Labels are read live, so
add it then re-run the gate job alone — no new push needed. It is a human's call: surface it
as an option with what would be shipping red, never add it yourself. Confirm both names on
the repo rather than trusting this file — `gh label list --repo trusk-official/<repo>`, and
the gate's own `bypass_label` default in `github-actions/.github/actions/ci-gate/action.yaml`.

## 4. Triage red

```bash
gh run view <id> --repo trusk-official/<repo> --log-failed \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -aE "✕|● |Tests:|error TS|prettier|Expected|Received"
```

Say which of the three it is: **your diff** (fix, push, back to 3); **environmental** —
suites that bootstrap Nest can't run locally, prove it with the same failure count on
`origin/master`; **flake** — hook timeouts on real third-party APIs, stale `node_modules`
changing outcomes; one `gh run rerun --failed`, and say you did. Two reruns without a
hypothesis isn't triage.

## 5. Report

Once `CI Gate` is green: PR number and URL, the commits as they'll land and the release each
implies, check results including the security comment, remaining gates (`mergeable` /
`mergeStateStatus` / required reviews), and what merging triggers — release, image, and
whether a `trusk-applications` bump follows. Then offer `/ship`. If it never goes green,
report the failure and what you ruled out.
