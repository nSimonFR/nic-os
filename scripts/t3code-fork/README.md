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
