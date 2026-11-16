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
  local files
  # --name-only hides merge diffs, so a local merge could smuggle in other files: refuse any.
  [ -z "$(git_ rev-list --merges "origin/$branch..HEAD")" ] || return 1
  files=$(git_ log --format= --name-only "origin/$branch..HEAD" 2>/dev/null | sort -u)
  [ -z "$files" ] || ! printf '%s\n' "$files" | grep -qv '^memory/'
}

sync_up() {
  local lock ahead behind tip target wt
  lock="$area/.git/memory-sync.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || return 0
    rm -rf "$lock" && mkdir "$lock" || return 0
  fi
  trap 'rm -rf "$lock"' RETURN
  git_ add -A -- memory
  if ! git_ diff --cached --quiet -- memory; then
    git_ commit -q --only -m "memory: sync from $(hostname -s)" -- memory
  fi
  tgit 30 fetch -q origin "$branch" || return 0
  only_memory_ahead || {
    echo "$(date -Is) skip: local commits beyond memory/"
    return 0
  }
  ahead=$(git_ rev-list --count "origin/$branch..HEAD")
  behind=$(git_ rev-list --count "HEAD..origin/$branch")
  tip=$(git_ rev-parse HEAD)
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
  {
    # Fast-forward only, bounded: it cannot outlive the hook timeout mid-rebase. When
    # local memory commits diverge from origin, the Stop hook's sync_up merges them.
    if tgit 6 fetch -q origin "$branch"; then
      tgit 4 merge -q --ff-only --autostash "origin/$branch" || true
    fi
  } >>"$log" 2>&1
  ;;
push)
  (sync_up >>"$log" 2>&1 &) </dev/null >/dev/null 2>&1
  ;;
esac
exit 0
