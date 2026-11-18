#!/usr/bin/env bash
# Claude Code hook: sync the shared auto-memory of a Home Repo (~/MyDocuments/PERSO or
# ~/MyDocuments/TRUSK, both git repos with a memory/ folder) between machines.
#
#   claude-memory-sync pull   SessionStart: fast-forward to origin before the index is read
#   claude-memory-sync push   Stop: commit memory/ only, merge, push — in the background
#
# Silent no-op when the session is not in an area, the area is not on its default
# branch, or local commits touch more than memory/ (never rewrites real work).
# Memory commits skip signing so the Pi, which has no key, can push them too.
# MEMORY.md uses merge=union (.gitattributes) so concurrent index lines both survive.
set -uo pipefail

mode=${1:-}
input=$(cat 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd=$PWD
real_cwd=$(cd "$cwd" && pwd -P) || exit 0
key=$(printf '%s' "$real_cwd" | sed 's/[^A-Za-z0-9]/-/g')
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)

# Self-heal at SessionStart: a session with no memory dir yet (a repo cloned into an area,
# a new T3 scratch thread) gets its area's shared store, before Claude Code creates an
# empty one. Claude keys memory by the canonical repo root (worktrees share the main
# checkout's), else by the cwd. T3 scratch threads (~/.t3/scratch) share PERSO.
# Only a missing or empty dir is replaced; anything else is left alone.
if [ "$mode" = pull ]; then
  root=$real_cwd
  case "$common" in */.git) root=$(cd "${common%/.git}" && pwd -P) || root=$real_cwd ;; esac
  store=""
  for a in "$HOME/MyDocuments/PERSO" "$HOME/MyDocuments/TRUSK"; do
    [ -d "$a/memory" ] && [ -e "$a/.git" ] || continue
    ra=$(cd "$a" && pwd -P)
    case "$root/" in "$ra"/*) store="$ra/memory" ;; esac
  done
  if [ -z "$store" ] && [ -d "$HOME/.t3/scratch" ] && [ -d "$HOME/MyDocuments/PERSO/memory" ]; then
    case "$root/" in "$(cd "$HOME/.t3/scratch" && pwd -P)"/*) store=$(cd "$HOME/MyDocuments/PERSO/memory" && pwd -P) ;; esac
  fi
  dir="$HOME/.claude/projects/$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')/memory"
  if [ -n "$store" ] && [ ! -L "$dir" ]; then
    { [ -d "$dir" ] && rmdir "$dir" 2>/dev/null; } || [ ! -e "$dir" ] && {
      mkdir -p "$(dirname "$dir")" && ln -s "$store" "$dir"
    }
  fi
fi
mem_link=$(readlink "$HOME/.claude/projects/$key/memory" 2>/dev/null || true)

area=""
for a in "$HOME/MyDocuments/PERSO" "$HOME/MyDocuments/TRUSK"; do
  [ -d "$a/memory" ] && [ -e "$a/.git" ] || continue
  ra=$(cd "$a" && pwd -P)
  case "$real_cwd/|$common|$mem_link" in
  "$ra"/* | *"|$ra"/* | *"|$ra/memory"*)
    area=$ra
    break
    ;;
  esac
done
[ -n "$area" ] || exit 0

log="$area/.git/memory-sync.log"
git_() { git -C "$area" -c commit.gpgsign=false "$@"; }
tgit() {
  local t=$1
  shift
  timeout "$t" git -C "$area" -c commit.gpgsign=false "$@"
}

# A rebase in progress leaves HEAD detached: the branch check below then exits.
branch=$(git_ symbolic-ref --short -q HEAD) || exit 0
# The push (backgrounded, no hook budget) asks the remote for its default branch, which
# survives a rename; the pull (15 s SessionStart budget) trusts the local origin/HEAD.
default=""
if [ "$mode" = push ]; then
  default=$(tgit 8 ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
fi
if [ -z "$default" ]; then
  default=$(git_ symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
  default=${default#origin/}
fi
[ "$branch" = "${default:-main}" ] || exit 0

only_memory_ahead() {
  local files rev=${1:-HEAD}
  # --name-only hides merge diffs, so a local merge could smuggle in other files: refuse any.
  [ -z "$(git_ rev-list --merges "origin/$branch..$rev")" ] || return 1
  files=$(git_ log --no-renames --format= --name-only "origin/$branch..$rev" 2>/dev/null | sort -u)
  [ -z "$files" ] || ! printf '%s\n' "$files" | grep -qv '^memory/'
}

# One lock for pull and push, so the pull's autostash can never interleave with the
# push's conflict check and staging. A lock older than 10 minutes is stale.
# Each invocation owns the lock it creates (token in lock/owner) and releases only that.
lock="$area/.git/memory-sync.lock"
token="$$.$RANDOM.$(date +%s)"
take_lock() {
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$token" >"$lock/owner"
    return 0
  fi
  [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || return 1
  # Stale takeover is serialized by a second mkdir lock: its holder re-checks staleness
  # before replacing, so a lock another hook just took over reads as fresh and is kept.
  # A takeover lock left by a crash (older than a minute) is cleared for the next run.
  if ! mkdir "$lock.takeover" 2>/dev/null; then
    [ -z "$(find "$lock.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rmdir "$lock.takeover" 2>/dev/null
    return 1
  fi
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rm -rf "$lock"
  fi
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$token" >"$lock/owner"
    rmdir "$lock.takeover"
    return 0
  fi
  rmdir "$lock.takeover"
  return 1
}
# shellcheck disable=SC2329 # invoked from the RETURN and EXIT traps
release_lock() {
  [ "$(cat "$lock/owner" 2>/dev/null)" = "$token" ] && rm -rf "$lock"
  return 0
}

sync_up() {
  local ahead behind tip target wt
  take_lock || return 0
  trap release_lock RETURN
  # A pull whose autostash hit a conflict leaves unmerged files or markers in memory/:
  # staging them would publish the markers as if resolved.
  if [ -n "$(git_ diff --name-only --diff-filter=U -- memory)" ] ||
    grep -rqE '^(<<<<<<<|>>>>>>>)( |$)' "$area/memory" 2>/dev/null; then
    echo "$(date -Is) skip: unresolved conflict in memory/"
    return 0
  fi
  git_ add -A -- memory
  if ! git_ diff --cached --quiet -- memory; then
    git_ commit -q --only -m "memory: sync from $(hostname -s)" -- memory
  fi
  tgit 30 fetch -q origin "$branch" || return 0
  # Every check and the merge below use this one captured commit, never a moving HEAD.
  tip=$(git_ rev-parse "refs/heads/$branch")
  only_memory_ahead "$tip" || {
    echo "$(date -Is) skip: local commits beyond memory/"
    return 0
  }
  ahead=$(git_ rev-list --count "origin/$branch..$tip")
  behind=$(git_ rev-list --count "$tip..origin/$branch")
  target="origin/$branch"
  if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
    # Diverged: merge in a private worktree this run owns, so an abort can never touch
    # the checkout, nor a rebase or merge the user started there.
    wt="$(git_ rev-parse --absolute-git-dir)/memory-sync-wt"
    git_ worktree remove --force "$wt" 2>/dev/null
    git_ worktree add -q --detach "$wt" "$tip" || return 1
    if git -C "$wt" -c commit.gpgsign=false merge -q --no-edit \
      -m "memory: merge sync from $(hostname -s)" "origin/$branch"; then
      tip=$(git -C "$wt" rev-parse HEAD)
      target=$tip
    else
      git -C "$wt" merge --abort
      tip=""
    fi
    git_ worktree remove --force "$wt"
    [ -n "$tip" ] || {
      echo "$(date -Is) skip: memory merge conflict"
      return 1
    }
  fi
  if [ "$ahead" -gt 0 ]; then
    tgit 30 push -q origin "$tip:refs/heads/$branch" || return 1
  fi
  # The checkout only ever fast-forwards: nothing to abort, and git refuses it on its
  # own when HEAD left the branch or a merge/rebase is in progress there.
  [ "$behind" -gt 0 ] || return 0
  [ "$(git_ symbolic-ref -q HEAD)" = "refs/heads/$branch" ] || return 0
  git_ merge -q --ff-only --autostash "$target"
}

case "$mode" in
pull)
  take_lock || exit 0
  trap release_lock EXIT
  {
    # Fast-forward only, bounded: it cannot outlive the hook timeout mid-rebase. When
    # local memory commits diverge from origin, the Stop hook's sync_up merges them.
    if tgit 6 fetch -q origin "$branch"; then
      tgit 4 merge -q --ff-only --autostash "origin/$branch" || true
    fi
  } >>"$log" 2>&1
  ;;
push)
  # Tests set MEMORY_SYNC_FOREGROUND: polling for the lock races the fork.
  if [ -n "${MEMORY_SYNC_FOREGROUND:-}" ]; then
    sync_up >>"$log" 2>&1 || true
  else
    (sync_up >>"$log" 2>&1 &) </dev/null >/dev/null 2>&1
  fi
  ;;
esac
exit 0
