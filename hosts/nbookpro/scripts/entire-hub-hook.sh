# shellcheck shell=bash
# entire-hub-hook <hook> — Entire's Claude hooks, also for sessions started in a
# folder of clones (~/MyDocuments/TRUSK) instead of a repo. Started in a repo: plain
# `entire hooks claude-code <hook>`. Started in the folder: a clone joins the
# session when a tool call (`route`) runs in it, writes in it or names it in a Bash
# command, before that call runs, so its commits get the Entire-Checkpoint
# trailer; every later hook goes to each joined clone.
command -v entire >/dev/null || exit 0
name=$1
input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
cwd=${cwd:-$PWD}
sid=$(jq -r '.session_id // empty' <<<"$input")

dir=${XDG_STATE_HOME:-$HOME/.local/state}/entire-hub
state=$dir/$sid
# A folder session stays one after its shell cd's into a clone.
if [ -z "$sid" ] || [ ! -f "$state" ]; then
  if [ "$name" != session-start ] || [ -z "$sid" ] ||
    git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
    [ "$name" = route ] && exit 0
    exec entire hooks claude-code "$name" <<<"$input"
  fi
  mkdir -p "$dir"
fi
touch "$state"

forward() { # forward <hook> <clone>
  (cd "$2" && jq -c --arg c "$2" '.cwd = $c' <<<"$input" | entire hooks claude-code "$1" >/dev/null 2>&1) || true
}

join() { # join <dir>: the clone holding <dir> joins the session
  local repo
  repo=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -d "$repo/.entire" ] || return 0
  grep -qxF "$repo" "$state" && return 0
  echo "$repo" >>"$state"
  forward session-start "$repo"
  forward user-prompt-submit "$repo"
}

if [ "$name" = route ]; then
  join "$cwd"
  f=$(jq -r '.tool_input | .file_path // .notebook_path // empty' <<<"$input")
  if [ -n "$f" ]; then
    case $f in /*) ;; *) f=$cwd/$f ;; esac
    while [ ! -d "$f" ] && [ "$f" != / ]; do f=$(dirname "$f"); done
    join "$f"
  fi
  jq -r '(.tool_input.command // "") | scan("[^\\s;&|()<>\"'"'"'=]+")' <<<"$input" | sort -u |
    while IFS= read -r w; do
      case $w in /*) p=$w ;; *) p=$cwd/$w ;; esac
      if [ -d "$p" ]; then join "$p"; fi
    done
  exit 0
fi

while IFS= read -r repo; do
  if [ -d "$repo" ]; then forward "$name" "$repo"; fi
done <"$state"
if [ "$name" = session-end ]; then rm -f "$state"; fi
# SessionEnd can be cut short when Claude exits.
find "$dir" -type f -mtime +7 -delete
