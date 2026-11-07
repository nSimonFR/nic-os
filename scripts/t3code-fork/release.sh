#!/usr/bin/env bash
# Publish the fork release from dl/ (both builds' artifacts).
# Needs VERSION TAG SHA BRANCH FORK and GH_TOKEN.
set -euo pipefail

rm dl/server-dist.tar.gz
(cd dl && sha256sum ./* | sed 's| \./| |' >SHA256SUMS)
cat >notes.md <<NOTES
Personal build for nic-os. Not an official release.

Built on \`$BRANCH\` (\`${SHA:0:10}\`): upstream \`$VERSION\` + the Issues stack and the other fork changes in \`spec.md\`, by .github/workflows/t3code-fork-release.yml in nSimonFR/nic-os.
The Mac app is upstream's with the fork's server swapped in and an ad hoc signature.
Issue migrations follow upstream's highest id; back up \`statev2.sqlite\` before running a new migration, it can't be rolled back.
NOTES
gh release create "$TAG" dl/* --repo "$FORK" --target "$SHA" --prerelease \
  --title "$TAG" --notes-file notes.md
