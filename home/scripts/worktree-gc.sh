#!/usr/bin/env bash
# worktree-gc [--dry-run] [--days N] — remove git worktrees nobody uses any more.
#
# Scans the Home Repos (~/MyDocuments/PERSO, ~/MyDocuments/TRUSK), their child checkouts,
# and the main repo of every worktree under ~/.t3/worktrees. A linked worktree goes only
# when all of these hold:
#   - not locked (`git worktree lock` keeps one forever);
#   - untouched for N days (default 7): no checkout, commit or index write in its git dir;
#   - clean: no modified, staged or untracked file (ignored files don't count);
#   - nothing to lose: every commit at HEAD is on a remote branch.
# Its local branch goes too when no other worktree has it and it is fully on a remote.
# A worktree whose directory is already gone is pruned. The main checkout is never touched.
# Written without errexit: guards like `[ -e x ] && ...` return 1 by design, and
# writeShellApplication turns errexit on, so it is switched back off here.
set +e -uo pipefail

dry=0
days=${WORKTREE_GC_DAYS:-7}
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) dry=1 ;;
  --days)
    days=$2
    shift
    ;;
  *)
    echo "usage: worktree-gc [--dry-run] [--days N]" >&2
    exit 2
    ;;
  esac
  shift
done

say() { printf '%s %s\n' "$(date +%FT%T)" "$*"; }

repos=()
add_repo() { [ -e "$1/.git" ] && repos+=("$(cd "$1" && pwd -P)"); }
for area in "$HOME/MyDocuments/PERSO" "$HOME/MyDocuments/TRUSK"; do
  [ -e "$area/.git" ] || continue
  add_repo "$area"
  while read -r p; do add_repo "$area/$p"; done < <(git -C "$area" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
done
for wt in "$HOME"/.t3/worktrees/*/*; do
  [ -d "$wt" ] || continue
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
  case "$common" in */.git) add_repo "${common%/.git}" ;; esac
done

# mtime in seconds, GNU or BSD stat.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
cutoff=$(($(date +%s) - days * 86400))

printf '%s\n' "${repos[@]}" | sort -u | while read -r repo; do
  path="" branch="" locked=0
  # One record per worktree, blank-line separated; the first is the main checkout.
  records=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || continue
  first=1
  while IFS= read -r line; do
    case "$line" in
    "worktree "*) path=${line#worktree } ;;
    "branch refs/heads/"*) branch=${line#branch refs/heads/} ;;
    locked*) locked=1 ;;
    "")
      if [ "$first" = 1 ]; then
        first=0
      elif [ -n "$path" ] && [ -d "$path" ] && [ "$locked" = 0 ]; then
        # A worktree whose .git link is broken can't be checked, so it is kept.
        gitdir=""
        if [ -f "$path/.git" ]; then
          gitdir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=""
        fi
        case "$gitdir" in */worktrees/*) ;; *)
          path="" branch="" locked=0
          continue
          ;;
        esac
        # Read the activity stamps before anything below could refresh the index.
        last=0
        for f in "$gitdir/HEAD" "$gitdir/index" "$gitdir/logs/HEAD"; do
          [ -e "$f" ] || continue
          t=$(mtime "$f")
          [ "$t" -gt "$last" ] && last=$t
        done
        if [ "$last" -lt "$cutoff" ] &&
          st=$(git -C "$path" --no-optional-locks status --porcelain --ignore-submodules=all 2>/dev/null) &&
          [ -z "$st" ] &&
          [ -z "$(git -C "$path" rev-list -n1 HEAD --not --remotes 2>/dev/null)" ]; then
          if [ "$dry" = 1 ]; then
            say "would remove $path${branch:+ ($branch)}"
          else
            # --force: a worktree of a Home Repo holds empty submodule dirs, which git
            # otherwise refuses to remove even when clean (checked just above).
            # Writable directories allow unlinking read-only files without changing their modes.
            find "$path" -type d -exec chmod u+w {} + 2>/dev/null
            if git -C "$repo" worktree remove --force "$path"; then
              say "removed $path"
              if [ -n "$branch" ] && [ "$branch" != main ] && [ "$branch" != master ] &&
                ! git -C "$repo" worktree list --porcelain | grep -qx "branch refs/heads/$branch" &&
                [ -z "$(git -C "$repo" rev-list -n1 "refs/heads/$branch" --not --remotes 2>/dev/null)" ]; then
                git -C "$repo" branch -q -D "$branch" && say "deleted branch $branch in $repo"
              fi
            fi
          fi
        fi
      fi
      path="" branch="" locked=0
      ;;
    esac
  done < <(printf '%s\n\n' "$records")
  [ "$dry" = 1 ] || git -C "$repo" worktree prune
done
exit 0
