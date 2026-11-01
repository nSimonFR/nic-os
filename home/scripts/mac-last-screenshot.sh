# shellcheck shell=sh
# Runs ON THE MAC (piped to `sh -s` by pbpaste). Prints the newest screenshot.
# Matched by the xattr screencapture sets, not the name: names are localized.
loc=$(defaults read com.apple.screencapture location 2>/dev/null) || loc=$HOME/Desktop
case $loc in "~"*) loc=$HOME${loc#"~"} ;; esac
# shellcheck disable=SC2012 # ls -t is the mtime sort macOS sh has
ls -t "$loc" | while IFS= read -r n; do
  f=$loc/$n
  if [ -f "$f" ] && xattr -p com.apple.metadata:kMDItemIsScreenCapture "$f" >/dev/null 2>&1; then
    echo "$f"
    break
  fi
done
