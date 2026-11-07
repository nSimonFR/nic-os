#!/usr/bin/env bash
# Repack upstream's macOS app with the fork's server. cwd is the nic-os checkout;
# dl/ holds the linux job's artifacts. Needs VERSION and GH_TOKEN.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

gh release download "v$VERSION" --repo pingdotgg/t3code \
  --pattern "T3-Code-$VERSION-arm64.zip" --dir dl
mkdir app dist out
ditto -x -k "dl/T3-Code-$VERSION-arm64.zip" app
tar -xzf dl/server-dist.tar.gz -C dist
(cd "$here" && npm install --no-audit --no-fund --no-package-lock)
node "$here/repack-mac.mjs" app dist "out/T3-Code-$VERSION-issues-darwin-arm64.zip"

contents="app/T3 Code (Nightly).app/Contents"
exe="$contents/MacOS/T3 Code (Nightly)"
server="$contents/Resources/app.asar/apps/server/dist/bin.mjs"
export ELECTRON_RUN_AS_NODE=1
got=$("$exe" "$server" --version)
echo "server --version: $got"
[[ $got == *"$VERSION"* ]]
