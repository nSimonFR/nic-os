#!/usr/bin/env bash
# Tests for home/scripts/worktree-gc.sh, against throwaway repos under a fake $HOME.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../worktree-gc.sh"
fail=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c commit.gpgsign=false -c init.defaultBranch=main -c protocol.file.allow=always "$@"; }
check() {
  local name=$1
  shift
  if "$@"; then echo "ok   $name"; else
    echo "FAIL $name"
    fail=1
  fi
}
age() { # make a worktree look untouched for 30 days
  local gd
  gd=$(g -C "$1" rev-parse --absolute-git-dir)
  touch -t 202001010000 "$gd/HEAD" "$gd/index" "$gd/logs/HEAD" 2>/dev/null
}

T=$(mktemp -d)
export HOME=$T
g init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/MyDocuments/PERSO" 2>/dev/null
P=$T/MyDocuments/PERSO
echo r >"$P/README.md"
g -C "$P" add -A
g -C "$P" commit -qm init
g -C "$P" push -q origin HEAD:main

mk() { # name: a worktree on a new branch, pushed
  g -C "$P" worktree add -q -b "$1" "$T/wt/$1" main
  g -C "$P" push -q origin "$1"
}
mk pushed
age "$T/wt/pushed"
mk dirty
echo x >"$T/wt/dirty/new.txt"
age "$T/wt/dirty"
mk unpushed
echo y >"$T/wt/unpushed/f"
g -C "$T/wt/unpushed" add f
g -C "$T/wt/unpushed" commit -qm local
age "$T/wt/unpushed"
mk recent
mk locked
g -C "$P" worktree lock "$T/wt/locked"
age "$T/wt/locked"
mk gone
rm -rf "$T/wt/gone"
mk broken
age "$T/wt/broken"
rm "$T/wt/broken/.git"
mk parent
age "$T/wt/parent"
g -C "$P" worktree add -q --detach "$T/wt/parent/ro" main
rm "$T/wt/parent/ro/.git"
mk readonly
mkdir -p "$T/wt/readonly/ro"
echo z >"$T/shared"
ln "$T/shared" "$T/wt/readonly/ro/f"
echo ro >>"$P/.git/info/exclude"
chmod 444 "$T/shared"
chmod 555 "$T/wt/readonly/ro"
age "$T/wt/readonly"

bash -e "$script" --dry-run >"$T/dry.log"
check "dry run removes nothing" test -d "$T/wt/pushed"
check "dry run names the candidate" grep -q "would remove .*/wt/pushed" "$T/dry.log"
check "dry run skips a nested worktree without its own .git file" test -z "$(grep 'would remove .*/wt/parent/ro' "$T/dry.log")"

# Keep the parent out of live cleanup so its ignored child can be checked separately.
g -C "$P" worktree lock "$T/wt/parent"
bash -e "$script" >/dev/null
check "old, clean, pushed worktree is removed" test ! -e "$T/wt/pushed"
check "its pushed branch is deleted" test -z "$(g -C "$P" branch --list pushed)"
check "dirty worktree is kept" test -f "$T/wt/dirty/new.txt"
check "worktree with unpushed commits is kept" test -d "$T/wt/unpushed"
check "recently used worktree is kept" test -d "$T/wt/recent"
check "locked worktree is kept" test -d "$T/wt/locked"
check "missing worktree is pruned" test -z "$(g -C "$P" worktree list | grep "$T/wt/gone")"
check "worktree with a broken .git link is kept" test -f "$T/wt/broken/README.md"
check "worktree with read-only files is removed" test ! -e "$T/wt/readonly"
check "file hard-linked outside the worktree keeps its mode" test -n "$(find "$T/shared" -perm 0444)"
check "main checkout is untouched" test -f "$P/README.md"

exit "$fail"
