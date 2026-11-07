#!/usr/bin/env bash
# In the merged fork checkout (cwd): install, stamp the version, gate, push the branch.
# Needs vp on PATH and VERSION; writes branch= and sha= to $GITHUB_OUTPUT.
set -euo pipefail

export pnpm_config_frozen_lockfile=false

vp install
node scripts/update-release-package-versions.ts "$VERSION"
vp install
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  # The fork's pre-commit hook runs knip, which has nothing to say about a stamp.
  git commit -q --no-verify -m "chore: stamp $VERSION and refresh the lockfile"
fi

# The effect language service prints a suggestion for most classes; keep the log
# quiet enough to find the task that actually failed.
if ! vp run typecheck >typecheck.log 2>&1; then
  grep -vE 'suggestion|TaggedError|^[0-9]+ +|^ *~+$|^$' typecheck.log | tail -80
  vp run --last-details || true
  exit 1
fi
(cd apps/server && vp test run src/persistence)

branch=$(git rev-parse --abbrev-ref HEAD)
git push origin "HEAD:refs/heads/$branch"
{
  echo "branch=$branch"
  echo "sha=$(git rev-parse HEAD)"
} >>"$GITHUB_OUTPUT"
