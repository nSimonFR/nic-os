# t3code fork release

Builds the `nSimonFR-ai/t3code` `-issues.1` release for each t3code version that
Renovate bumps in `pkgs/agents/t3code.nix`; driven by
`.github/workflows/t3code-fork-release.yml`. The fork is upstream's release plus
the small changes in its `spec.md`; it carried the Issues stack up to 0.1.10 and
dropped it at 0.1.11, when upstream shipped Issues. The `-issues` suffix stayed
so the workflow (which the bot can't edit) needs no change.

| Script | Job |
| --- | --- |
| `merge-upstream.sh` | merge the release into the fork's `nicos/fork-X.Y.Z` branch, keeping the fork's `.github/workflows` and `spec.md` base |
| `assemble-linux.sh` | upstream's linux-arm64 archive with the fork's `t3` and `client/` |
| `repack-mac.mjs` | upstream's macOS app with the fork's server and client, re-signed ad hoc |
| `pin-hashes.py` | write the three asset hashes into `pkgs/agents/t3code*.nix` |

The Mac build keeps upstream's Electron main and preload processes: a fork change
there never ships, so the fork changes only the server and the web client.

A merge conflict beyond `pnpm-lock.yaml` (exit 10), or a failing typecheck or
persistence test, stops the run with a PR comment. Resolve it by hand on the fork
branch against its `spec.md`, publish the release, and re-run the workflow.
A rebuild of an existing version (`-issues.2`) is manual too.

## Resolving a conflicted bump by hand

Do it in a clone of the fork, then push the merged `nicos/fork-X.Y.Z` branch (a
merge commit of the previous fork branch and the upstream tag); the workflow sees
the tag already merged and goes on to stamp, gate and build.

1. `git checkout -B tmp-merge origin/<previous branch>`, `git merge --no-commit <tag>`.
2. Keep upstream for everything the spec does not list. Never `--theirs` a `package.json`: use `git merge-file --theirs` against the merge base instead, so only the version conflicts go to upstream.
3. `git rm -rf .github/workflows && git checkout origin/main -- .github/workflows`.
4. Gate it as `prepare.sh` does: `vp install`, `vp run typecheck` (use the repo's own `vp`, not a newer one), `vp test run src/persistence` in `apps/server`.
5. `git commit-tree` with both parents, push, re-run the workflow.
