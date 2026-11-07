#!/usr/bin/env bash
# Build the fork's linux-arm64 archive into out/. cwd is the workspace holding
# nicos/ (this repo) and t3code/ (the merged fork). Needs vp, VERSION and GH_TOKEN.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

(cd t3code/apps/web && vp build)
(cd t3code/apps/server && node scripts/cli.ts build)
(cd t3code && node scripts/apply-web-brand-assets.ts nightly apps/server/dist/client)
(cd t3code && node apps/server/scripts/cli.ts build-exe --verbose)

mkdir -p out
gh release download "v$VERSION" --repo pingdotgg/t3code \
  --pattern "t3-$VERSION-linux-arm64.tar.gz" --dir out
"$here/assemble-linux.sh" "out/t3-$VERSION-linux-arm64.tar.gz" \
  t3code/apps/server/dist-exe/t3 t3code/apps/server/dist/client \
  "out/t3-$VERSION-issues-linux-arm64.tar.gz"
rm "out/t3-$VERSION-linux-arm64.tar.gz"

mkdir smoke
tar -xzf "out/t3-$VERSION-issues-linux-arm64.tar.gz" -C smoke
t3=(smoke/*/t3)
got=$("${t3[0]}" --version)
echo "t3 --version: $got"
[[ "$got" == *"$VERSION"* ]]

# The macOS job needs the server build too.
tar -C t3code/apps/server/dist -czf out/server-dist.tar.gz .
