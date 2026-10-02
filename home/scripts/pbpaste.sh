# Reads the Mac's clipboard over SSH, on demand. Nothing is synced or kept here.
# MAC_CLIP_JS and MAC_LAST_SCREENSHOT are prepended by home/mac-clipboard.nix.
host=${PBPASTE_HOST:-macbook-pro-appleosx-15}

usage() {
  cat <<'EOF'
usage: pbpaste                      clipboard text to stdout
       pbpaste --image [FILE]       save the clipboard image as PNG, print its path
       pbpaste --screenshot [FILE]  fetch the latest saved screenshot, print its path
       pbpaste --files [DIR]        copy the files copied in Finder, print their paths
       pbpaste --types              list the clipboard's types
EOF
}

die() {
  echo "pbpaste: $*" >&2
  exit 1
}

# accept-new: the tailnet already authenticates the Mac, and a host key known
# only on the host it was first accepted on broke every other host.
mac() {
  local rc=0
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "$host" "$@" || rc=$?
  ((rc != 255)) || die "cannot reach $host (asleep or off the tailnet?)"
  return "$rc"
}
helper() { mac osascript -l JavaScript - "$1" <"$MAC_CLIP_JS"; }

case "${1:-}" in
  # Without a UTF-8 locale (ssh sets none) pbpaste turns non-ASCII into '?'.
  "") mac LC_CTYPE=UTF-8 pbpaste </dev/null ;;
  --types) helper types ;;
  --image)
    out=${2:-$(mktemp --tmpdir pbpaste-XXXXXX.png)}
    helper image | base64 -d >"$out"
    [[ -s "$out" ]] || { rm -f "$out"; die "no image on the clipboard (⌘⇧4 saves a file: try --screenshot)"; }
    echo "$out"
    ;;
  --screenshot)
    shot=$(mac sh -s <"$MAC_LAST_SCREENSHOT")
    [[ -n "$shot" ]] || die "no saved screenshot found"
    out=${2:-$(mktemp --tmpdir "pbpaste-XXXXXX.${shot##*.}")}
    mac cat -- "$(printf %q "$shot")" </dev/null >"$out"
    echo "$out"
    ;;
  --files)
    out=${2:-$(mktemp -d --tmpdir pbpaste-XXXXXX)}
    mkdir -p "$out"
    paths=$(helper files)
    [[ -n "$paths" ]] || die "no files on the clipboard"
    while IFS= read -r p; do
      mac "tar -cf - -C $(printf %q "$(dirname "$p")") $(printf %q "$(basename "$p")")" </dev/null |
        tar -xf - -C "$out"
      echo "$out/$(basename "$p")"
    done <<<"$paths"
    ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
