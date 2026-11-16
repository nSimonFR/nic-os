#!/usr/bin/env bash
# Claude Code hook: sync the shared auto-memory of a Home Repo (~/MyDocuments/PERSO or
# ~/MyDocuments/TRUSK, both git repos with a memory/ folder) between machines.
#
#   claude-memory-sync pull   SessionStart: rebase onto origin before the index is read
#   claude-memory-sync push   Stop: commit memory/ only, rebase, push — in the background
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
    "$ra"/*|*"|$ra"/*|*"|$ra/memory"*) area=$ra; break ;;
  esac
done
[ -n "$area" ] || exit 0

log="$area/.git/memory-sync.log"
git_() { git -C "$area" -c commit.gpgsign=false "$@"; }
tgit() { local t=$1; shift; timeout "$t" git -C "$area" -c commit.gpgsign=false "$@"; }

branch=$(git_ symbolic-ref --short -q HEAD) || exit 0
default=$(git_ symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)
default=${default#origin/}
[ "$branch" = "${default:-main}" ] || exit 0

only_memory_ahead() {
  local files
  files=$(git_ log --format= --name-only "origin/$branch..HEAD" 2>/dev/null | sort -u)
  [ -z "$files" ] || ! printf '%s\n' "$files" | grep -qv '^memory/'
}

sync_up() {
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
  only_memory_ahead || { echo "$(date -Is) skip: local commits beyond memory/" ; return 0; }
  git_ rebase -q --autostash "origin/$branch" || { git_ rebase --abort; return 1; }
  [ -z "$(git_ rev-list "origin/$branch..HEAD")" ] || tgit 30 push -q origin "$branch"
}

case "$mode" in
  pull)
    {
      tgit 8 fetch -q origin "$branch" &&
        only_memory_ahead &&
        git_ rebase -q --autostash "origin/$branch" || git_ rebase --abort 2>/dev/null
    } >>"$log" 2>&1
    ;;
  push)
    ( sync_up >>"$log" 2>&1 & ) </dev/null >/dev/null 2>&1
    ;;
esac
exit 0
