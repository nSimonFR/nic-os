#!/usr/bin/env bash
# Tests for home/scripts/claude-memory-sync.sh, against throwaway git repos.
# Each case builds a bare origin, a second clone ("the other machine") and the area
# checkout at $HOME/MyDocuments/PERSO, then runs the hook as Claude Code would.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../claude-memory-sync.sh"
fail=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

setup() {
  T=$(mktemp -d)
  export HOME=$T
  g init -q --bare "$T/origin.git"
  g clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  mkdir -p "$T/seed/memory"
  echo "- [a](a.md)" >"$T/seed/memory/MEMORY.md"
  echo a >"$T/seed/memory/a.md"
  echo r >"$T/seed/README.md"
  echo 'memory/MEMORY.md merge=union' >"$T/seed/.gitattributes"
  g -C "$T/seed" add -A
  g -C "$T/seed" commit -qm init
  g -C "$T/seed" push -q origin HEAD:main
  g --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "$T/MyDocuments"
  g clone -q "$T/origin.git" "$T/MyDocuments/PERSO"
  g clone -q "$T/origin.git" "$T/other"
  L=$T/MyDocuments/PERSO
  K=$L/.git/memory-sync.lock
}
hook() { printf '{"cwd":"%s"}' "$L" | bash "$script" "$1"; }
push_hook() { MEMORY_SYNC_FOREGROUND=1 hook push; }
other_commit() { # file content
  g -C "$T/other" pull -q --no-rebase
  echo "$2" >"$T/other/memory/$1"
  g -C "$T/other" add -A
  g -C "$T/other" commit -qm "$1"
  g -C "$T/other" push -q
}
# shellcheck disable=SC2329 # called through check
in_sync() { [ "$(g -C "$L" rev-parse HEAD)" = "$(g --git-dir="$T/origin.git" rev-parse main)" ]; }
origin_at() { g --git-dir="$T/origin.git" rev-parse main; }
check() { # name condition...
  local name=$1
  shift
  if "$@"; then echo "ok   $name"; else
    echo "FAIL $name"
    fail=1
  fi
}

# Divergent memory on both machines merges, MEMORY.md keeps both index lines.
setup
other_commit b.md b
echo "- [b](b.md)" >>"$T/other/memory/MEMORY.md"
g -C "$T/other" commit -qam idx-b
g -C "$T/other" push -q
echo c >"$L/memory/c.md"
echo "- [c](c.md)" >>"$L/memory/MEMORY.md"
push_hook
check "divergence merges and pushes" in_sync
check "divergence keeps both files" test -f "$L/memory/b.md" -a -f "$L/memory/c.md"
check "union index keeps both lines" grep -q 'b.md' "$L/memory/MEMORY.md"
check "union index keeps local line" grep -q 'c.md' "$L/memory/MEMORY.md"

# Same file edited on both sides: skipped, checkout left clean of merge state.
other_commit a.md a-other
echo a-local >"$L/memory/a.md"
before=$(origin_at)
push_hook
check "same-file conflict leaves origin alone" test "$before" = "$(origin_at)"
check "same-file conflict leaves no merge state" test ! -e "$L/.git/MERGE_HEAD"
check "same-file conflict removes its worktree" test "$(g -C "$L" worktree list | wc -l)" -eq 1

# The Stop hook's default, background push still lands (deadline 30 s).
setup
echo d >"$L/memory/d.md"
before=$(origin_at)
hook push
for _ in $(seq 1 120); do
  [ "$(origin_at)" != "$before" ] && [ ! -d "$K" ] && break
  sleep 0.25
done
check "background push reaches origin" test "$(origin_at)" != "$before"

# Local commits outside memory/ (plain or a rename into memory/) are never pushed.
setup
echo z >"$L/code.txt"
g -C "$L" add code.txt
g -C "$L" commit -qm code
before=$(origin_at)
push_hook
check "non-memory commit is not pushed" test "$before" = "$(origin_at)"
setup
g -C "$L" mv README.md memory/README.md
g -C "$L" commit -qm move
before=$(origin_at)
push_hook
check "rename out of memory/ is not pushed" test "$before" = "$(origin_at)"

# Conflict markers in memory/ are never staged.
setup
printf '<<<<<<< Updated upstream\nx\n=======\ny\n>>>>>>> Stashed changes\n' >"$L/memory/a.md"
before=$(origin_at)
push_hook
check "conflict markers are not published" test "$before" = "$(origin_at)"

# A held lock makes pull a no-op; a stale one is taken over and released.
setup
other_commit b.md b
mkdir "$K"
echo other >"$K/owner"
hook pull
check "pull skips while another holds the lock" test ! -f "$L/memory/b.md"
check "a held lock is left to its owner" test "$(cat "$K/owner")" = other
touch -t 202001010000 "$K"
hook pull
check "a stale lock is taken over" test -f "$L/memory/b.md"
check "the taken-over lock is released" test ! -e "$K"
check "no takeover lock is left behind" test ! -e "$K.takeover"

# Forced interleaving: hook B saw the lock as stale, then hook A replaced it before B
# took over. A stub find reports "stale" once (B's first check), then defers to the real
# find; B must re-check under the takeover lock, see A's fresh lock and back off.
setup
other_commit b.md b
mkdir "$K"
echo hook-A >"$K/owner"
stub=$T/stub
mkdir -p "$stub"
real_find=$(command -v find)
cat >"$stub/find" <<EOF
#!/usr/bin/env bash
if [ ! -e "$stub/used" ] && [ "\$1" = "$K" ]; then touch "$stub/used"; echo "$K"; exit 0; fi
exec "$real_find" "\$@"
EOF
chmod +x "$stub/find"
printf '{"cwd":"%s"}' "$L" | PATH="$stub:$PATH" bash "$script" pull
check "interleaved takeover keeps hook A's fresh lock" test "$(cat "$K/owner" 2>/dev/null)" = hook-A
check "interleaved hook B does not sync" test ! -f "$L/memory/b.md"
check "interleaved hook B releases the takeover lock" test ! -e "$K.takeover"

# Self-heal: a new scratch thread and a repo cloned into the area get the shared store;
# a memory dir that already holds notes is never replaced.
setup
mkey() { printf '%s' "$(cd "$1" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g'; }
mkdir -p "$T/.t3/scratch/2026-11-17-thread"
printf '{"cwd":"%s"}' "$T/.t3/scratch/2026-11-17-thread" | bash "$script" pull
check "scratch thread links to PERSO memory" \
  test "$(readlink "$T/.claude/projects/$(mkey "$T/.t3/scratch/2026-11-17-thread")/memory")" = "$(cd "$L/memory" && pwd -P)"
g init -q "$L/newrepo"
mkdir -p "$L/newrepo/src"
printf '{"cwd":"%s"}' "$L/newrepo/src" | bash "$script" pull
check "new repo in the area links by its root" \
  test -L "$T/.claude/projects/$(mkey "$L/newrepo")/memory"
mkdir -p "$T/.t3/scratch/kept"
mkdir -p "$T/.claude/projects/$(mkey "$T/.t3/scratch/kept")/memory"
echo note >"$T/.claude/projects/$(mkey "$T/.t3/scratch/kept")/memory/n.md"
printf '{"cwd":"%s"}' "$T/.t3/scratch/kept" | bash "$script" pull
check "a memory dir with notes is left alone" \
  test -f "$T/.claude/projects/$(mkey "$T/.t3/scratch/kept")/memory/n.md"
mkdir -p "$T/elsewhere"
printf '{"cwd":"%s"}' "$T/elsewhere" | bash "$script" pull
check "a session outside the areas gets no link" \
  test ! -e "$T/.claude/projects/$(mkey "$T/elsewhere")/memory"

exit "$fail"
