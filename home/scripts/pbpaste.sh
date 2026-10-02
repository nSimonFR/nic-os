# Reads the Mac's clipboard over SSH, on demand. Nothing is synced or kept here.
# MAC_CLIP_JS is prepended by home/mac-clipboard.nix.
host=${PBPASTE_HOST:-macbook-pro-appleosx-15}

usage() {
  cat <<'EOF'
usage: pbpaste                 clipboard text to stdout
       pbpaste --image [FILE]  save the clipboard image as PNG, print its path
       pbpaste --screenshot [FILE]  fetch the latest saved screenshot, print its path
       pbpaste --files [DIR]   copy the files copied in Finder, print their paths
       pbpaste --types         list the clipboard's types
EOF
}

mac() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "$@"; }
helper() { mac osascript -l JavaScript - "$1" <"$MAC_CLIP_JS"; }

case "${1:-}" in
  "") mac pbpaste ;;
  --types) helper types ;;
  --image)
    out=${2:-$(mktemp --tmpdir pbpaste-XXXXXX.png)}
    b64=$(helper image)
    if [[ -z "$b64" ]]; then
      echo "pbpaste: no image on the clipboard" >&2
      exit 1
    fi
    base64 -d <<<"$b64" >"$out"
    echo "$out"
    ;;
  --screenshot)
    # ⌘⇧4 saves a file instead of touching the clipboard. /tmp, the location
    # set on this Mac, isn't indexed by Spotlight, hence matching by name.
    shot=$(mac sh -s <<'EOF'
loc=$(defaults read com.apple.screencapture location 2>/dev/null || echo "$HOME/Desktop")
ls -t "$loc"/Screenshot*.png "$loc"/Capture*.png 2>/dev/null | head -1
EOF
    )
    if [[ -z "$shot" ]]; then
      echo "pbpaste: no saved screenshot found" >&2
      exit 1
    fi
    out=${2:-$(mktemp --tmpdir pbpaste-XXXXXX.png)}
    mac cat -- "$(printf %q "$shot")" </dev/null >"$out"
    echo "$out"
    ;;
  --files)
    out=${2:-$(mktemp -d --tmpdir pbpaste-XXXXXX)}
    mkdir -p "$out"
    paths=$(helper files)
    if [[ -z "$paths" ]]; then
      echo "pbpaste: no files on the clipboard" >&2
      exit 1
    fi
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
