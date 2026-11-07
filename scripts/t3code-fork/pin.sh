#!/usr/bin/env bash
# Pin the release's hashes in the checked-out PR branch and push the change.
# Needs VERSION TAG HEAD_REF FORK and GH_TOKEN.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

mkdir dl
gh release download "$TAG" --repo "$FORK" --dir dl \
  --pattern '*-linux-arm64.tar.gz' --pattern '*-darwin-arm64.zip'
gh release download "v$VERSION" --repo pingdotgg/t3code --dir dl \
  --pattern "t3-$VERSION-darwin-arm64.tar.gz"
python3 "$here/pin-hashes.py" \
  "dl/t3-$VERSION-issues-linux-arm64.tar.gz" \
  "dl/t3-$VERSION-darwin-arm64.tar.gz" \
  "dl/T3-Code-$VERSION-issues-darwin-arm64.zip"
if [ -n "$(git status --porcelain)" ]; then
  git config user.name nSimonFR-ai
  git config user.email 265587706+nSimonFR-ai@users.noreply.github.com
  git commit -q -am "chore(t3code): pin the $TAG hashes"
  git push origin "HEAD:$HEAD_REF"
fi
