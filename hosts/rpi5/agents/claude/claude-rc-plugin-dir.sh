# Build the bridge's own plugins/ directory (managed by
# claude-remote-control.nix, run from claude-rc-prep-config at bridge start):
# one shared set of clones, but
# per-config-dir path bookkeeping.
#
# Why this exists: claude-code validates the absolute paths recorded in
# known_marketplaces.json (installLocation) and installed_plugins.json
# (installPath) with a RAW STRING PREFIX TEST against
# $CLAUDE_CONFIG_DIR/plugins/... — it does not resolve symlinks. Measured
# 2026-08-19: the identical value passes under CLAUDE_CONFIG_DIR=~/.claude and
# fails under ~/.claude-rc with
#   "Marketplace 'x' has a corrupted installLocation (...) — expected a path
#    inside /home/nsimon/.claude-rc/plugins/marketplaces"
# and vice versa. So a single shared registry file can satisfy only ONE of the
# two config dirs; the loser is silently skipped by the auto-updater
# (FORCE_AUTOUPDATE_PLUGINS=1), which is how the mattpocock marketplace sat 133
# commits behind for a month while the other two stayed current.
#
# Fix: give the bridge a real plugins/ dir whose heavy state (marketplaces/ git
# clones, cache/ unpacked versions) is symlinked to ~/.claude's, and whose two
# registry files are generated copies with the paths rewritten to the bridge's
# own prefix. Both surfaces then validate against one set of clones.
#
# ~/.claude stays authoritative, same as settings.json: this regenerates the
# bridge's copy on every bridge start, so a version bump made from a normal
# session reaches the bridge on its next restart, while an install/update
# initiated from a *bridge* session loses only its bookkeeping (the git pull and
# the unpacked version land in the shared dirs regardless). The structural win
# is that the bridge can no longer write ~/.claude-rc paths into the shared
# registries, which is what corrupted them in the first place.
#
# Usage: claude-rc-plugin-dir <src-plugins-dir> <dst-plugins-dir>
# Needs jq and coreutils on PATH (the caller exports them).
set -eu

src="$1"
dst="$2"

[ -d "$src" ] || exit 0

# Earlier generations symlinked the whole plugins/ dir. Drop that first —
# otherwise mkdir -p follows it and we would write into $src itself.
[ -L "$dst" ] && rm -f "$dst"
mkdir -p "$dst"

# Shared heavy state. Never clobber a real directory here: if a bridge session
# ever wrote genuine state into it, warn instead of destroying it.
link_shared() {
  local name="$1" target="$dst/$1"
  [ -e "$src/$name" ] || return 0
  if [ -L "$target" ] || [ ! -e "$target" ]; then
    ln -sfn "$src/$name" "$target"
  elif [ -d "$target" ] && [ -z "$(ls -A "$target")" ]; then
    rmdir "$target"
    ln -s "$src/$name" "$target"
  else
    echo "claude-rc plugins: $target holds real state; not linking to $src/$name" >&2
  fi
}
link_shared marketplaces
link_shared cache

# The registries: copy with every $src-prefixed path rewritten to $dst. walk()
# catches installLocation, installPath and any future path field without this
# script having to know the schema.
for reg in known_marketplaces.json installed_plugins.json; do
  [ -f "$src/$reg" ] || continue
  rm -f "$dst/$reg"
  jq --arg src "$src" --arg dst "$dst" \
    'walk(if type == "string" and startswith($src) then $dst + .[($src | length):] else . end)' \
    "$src/$reg" > "$dst/$reg"
done

# Everything else (blocklist.json, .last_inuse_sweep, ...) carries no per-config
# path, so share it outright.
for entry in "$src"/* "$src"/.[!.]*; do
  [ -e "$entry" ] || continue
  name="$(basename "$entry")"
  case "$name" in
    marketplaces | cache | known_marketplaces.json | installed_plugins.json) continue ;;
  esac
  ln -sfn "$entry" "$dst/$name"
done
