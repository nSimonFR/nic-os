# t3code fork release

Builds the `nSimonFR-ai/t3code` `-issues.1` release for each t3code nightly that
Renovate bumps in `pkgs/agents/t3code.nix`; driven by
`.github/workflows/t3code-fork-release.yml`.

| Script | Job |
| --- | --- |
| `merge-upstream.sh` | merge the nightly into the fork's `nicos/issues-nightly-X.Y.Z` branch, keeping the fork's `.github/workflows` and `spec.md` base |
| `migrations.mjs` | move the fork's issue migrations after upstream's highest id (`detach` before the merge, `attach` after) |
| `assemble-linux.sh` | upstream's linux-arm64 archive with the fork's `t3` and `client/` |
| `repack-mac.mjs` | upstream's macOS app with the fork's server, re-signed ad hoc |
| `pin-hashes.py` | write the three asset hashes into `pkgs/agents/t3code*.nix` |

A merge conflict beyond `pnpm-lock.yaml` (exit 10), or a failing typecheck or
migration test, stops the run with a PR comment. Resolve it by hand on the fork
branch against its `spec.md`, publish the release, and re-run the workflow.
A rebuild of an existing nightly (`-issues.2`) is manual too.

## Resolving a conflicted bump by hand

Do it in a clone of the fork, then push the merged `nicos/issues-nightly-X.Y.Z`
branch (a merge commit of the previous fork branch and the upstream tag); the
workflow sees the tag already merged and goes on to stamp, gate and build.

1. `git checkout -B tmp-merge origin/<previous branch>`, `node migrations.mjs detach`, commit, `git merge --no-commit <tag>`.
2. Keep upstream for everything the spec does not list. Never `--theirs` a `package.json`: that drops the fork's workspace dependencies. Use `git merge-file --theirs` against the merge base instead, so only the version conflicts go to upstream.
3. `git rm -rf .github/workflows && git checkout origin/main -- .github/workflows`, then `node migrations.mjs attach`.
4. Gate it as `prepare.sh` does: `vp install`, `vp run typecheck` (use the repo's own `vp`, not a newer one), `vp test run src/persistence` in `apps/server`.
5. `git commit-tree` with both parents, push, re-run the workflow.

At 0.1.10 (the layout redesign) the typecheck gate needed: fork packages on `effect-tsgo`, `variant="outline"` → `"secondary"`, and the Issues page as a layout page tab.
