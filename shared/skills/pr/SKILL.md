---
name: pr
description: Open a pull request from the current branch and watch it to a verdict — commits and body written to the repo's conventions, push, create, then follow CI and merge gates until they settle. Use when asked to "open a PR", "faire une PR", "push this and watch CI", to write or rewrite a PR body, or to track an existing PR's checks. Does not merge.
---

# /pr — open a PR, watch it to a verdict

Branch → PR → green gate, then a report: mergeable, or why not.

Args: nothing (current repo + branch), or a PR number/URL to jump to step 4.

## 1. Conventions

Read the repo's own rules before anything else; **they win over this file** wherever they
speak. Sources, nearest first: `CLAUDE.md` / `AGENTS.md` (walking up from the repo), any note
they index for PRs, CI or releases, `CONTRIBUTING.md`, `.github/pull_request_template.md`.
Pull out: commit format and how releases are cut from it, which account pushes and opens
PRs, draft or not, how an issue gets linked, the base branch.

Done when you can name each of those, or know the repo is silent on it.

## 2. Before creating

Not on the base branch. `gh pr list --head <branch>` — if a PR exists, update it instead of
opening a second. Read the full diff and say what it does.

**Commits are what lands.** On a rebase-merge repo each one ships verbatim and release
tooling parses them, so fix messages now, not in the title. Changed a signature or return
type? Grep its callers and test doubles yourself; a passing typecheck is not proof.

## 3. Create

Push, then `gh pr create --base <base> --title … --body-file -`, with the account and flags
from step 1. Write the body from [`references/body.md`](references/body.md); a repo template
takes precedence, with the reference's sections folded into it where they fit.

Print the PR's full URL — a bare number is a search.

## 4. Watch

List the checks and which are **required** (`gh pr checks <n> --required`, the branch
ruleset). Find the run by **headSha**, not by name — workflow names rarely match the PR
title. Wait on it with Monitor:

```
until [ "$(gh run view <ID> --json status --jq .status)" = completed ]; do sleep 30; done \
  && gh pr checks <n>
```

A pushed fix starts a new run: re-resolve the ID. Done when every required check has
concluded.

## 5. Triage red

```bash
gh run view <id> --log-failed | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -aiE "error|fail|✕|● |expected|received" | head -80
```

Name which it is:

- **your diff** — fix, push, back to 4;
- **environmental** — prove it with the same failure on the base branch's latest run;
- **flake** — timeouts against real third-party APIs, ordering, caches; one
  `gh run rerun --failed`, and say you did.

Two reruns without a hypothesis isn't triage. A bypass label or `--admin` is a human's call:
surface it with what would ship red, never apply it yourself.

## 6. Report

Once the required checks are green: the PR's full URL, the commits as they will land and the
release each implies, check results (bot and security comments included), what still gates
the merge (`mergeable`, `mergeStateStatus`, required reviews), and what merging triggers. If
it never went green: the failure, and what you ruled out.
