# entire-brain-trusk — one Brain pass over every Trusk clone that has Entire
# sessions, all members of the "trusk" workspace so `entire brain workspace
# query` searches them as one. Dirty clones are seeded as they are (--worktree):
# these are working copies, and Brain refuses them otherwise.

root=${TRUSK_DIR:-$HOME/MyDocuments/TRUSK}
max=${ENTIRE_BRAIN_MAX_SESSIONS:-10}

find "$root" -maxdepth 5 -name node_modules -prune -o -name settings.local.json -path '*/.entire/*' -print |
  while read -r s; do
    r=$(dirname "$(dirname "$s")")
    [ -e "$r/.git" ] || continue
    if [ -f "$r/.git" ] && grep -q /worktrees/ "$r/.git"; then continue; fi
    [ -n "$(git -C "$r" for-each-ref --count=1 refs/entire)" ] || continue

    cd "$r" || continue
    entire-brain workspace add trusk "$r" >/dev/null 2>&1 || true
    w=
    [ -n "$(git status --porcelain | head -1)" ] && w=--worktree
    entire-brain refresh $w >/dev/null 2>&1 || echo "refresh failed: $r"
    entire-brain distill --agent claude-code --model haiku --newest-first --max-sessions "$max" >/dev/null 2>&1 ||
      echo "distill failed: $r"
    entire-brain memories sync >/dev/null 2>&1 || true
  done
