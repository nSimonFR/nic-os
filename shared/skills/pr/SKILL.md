---
name: pr
description: Open a pull request from the current branch and watch CI to a verdict. Use when asked to "open a PR", "faire une PR", "push this and watch CI", to write a PR body, or to track an existing PR's checks. Does not merge.
---

# /pr

Args: nothing (current branch), or a PR number/URL to start at step 4.

1. **Conventions.** The repo's rules win over this file. Read `CLAUDE.md` / `AGENTS.md`
   (and the notes they index for PRs/CI), `CONTRIBUTING.md`, the PR template. Extract:
   commit format, push/PR account, draft or not, issue linking, base branch.
2. **Check.** Not on base. `gh pr list --head <branch>` — update an existing PR, never open
   a second. Read the full diff. On rebase-merge repos every commit lands verbatim: fix
   messages now. Changed a signature? Grep its callers and test doubles yourself.
3. **Create.** Push, `gh pr create --base <base> --body-file -` with step 1's account and
   flags. Body from [`references/body.md`](references/body.md), folded into the repo
   template if there is one. Print the full URL.
4. **Watch.** Note the **required** checks (`gh pr checks <n> --required`). Find the run by
   **headSha**, not name, and wait with Monitor:
   `until [ "$(gh run view <id> --json status -q .status)" = completed ]; do sleep 30; done`.
   A new push means a new run ID.
5. **Triage red.**
   `gh run view <id> --log-failed | sed 's/\x1b\[[0-9;]*m//g' | grep -aiE "error|fail|expected|received" | head -80`
   — then name it: **your diff** (fix, push, back to 4), **environmental** (same failure on
   base's latest run), or **flake** (one `gh run rerun --failed`, say so). Bypass labels and
   `--admin` are a human's call: surface them, never apply.
6. **Report.** Full URL, the commits as they'll land, check results (bot/security comments
   too), what still gates the merge (`mergeStateStatus`, reviews). If never green: the
   failure and what you ruled out.
