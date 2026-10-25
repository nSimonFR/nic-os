# entire-trusk-enable [--apply] — turn Entire on, privately, in every
# trusk-official clone or submodule under $TRUSK_DIR (default ~/MyDocuments/TRUSK),
# up to four levels deep (trusk-infra nests its services as submodules).
#
# Per clone: git hooks, a gitignored .entire/settings.local.json routing
# checkpoints to nSimonFR/trusk-checkpoints, and a post-checkout hook that copies
# those settings into new worktrees. Agent hooks are machine-wide
# (hosts/nbookpro/entire.nix), so the repo-level Claude hooks that `entire enable`
# writes are put back. Re-run after cloning a new repo. Dry run by default.

apply=0
[ "${1:-}" = "--apply" ] && apply=1
root=${TRUSK_DIR:-$HOME/MyDocuments/TRUSK}
remote=github:nSimonFR/trusk-checkpoints
marker="# entire-trusk-enable: worktree settings"

post_checkout_hook() {
  cat <<EOF
#!/bin/sh
$marker
top=\$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
main=\$(git worktree list --porcelain | sed -n '1s/^worktree //p')
[ "\$top" = "\$main" ] && exit 0
[ -f "\$top/.entire/settings.local.json" ] && exit 0
[ -f "\$main/.entire/settings.local.json" ] || exit 0
mkdir -p "\$top/.entire"
cp "\$main/.entire/settings.local.json" "\$main/.entire/.gitignore" "\$top/.entire/" 2>/dev/null
exit 0
EOF
}

enable_clone() {
  local dir=$1 claude=.claude/settings.json tracked=0 existed=0
  cd "$dir" || return 1
  if git ls-files --error-unmatch "$claude" >/dev/null 2>&1; then
    tracked=1
    if ! git diff --quiet -- "$claude"; then
      echo "skip $dir: uncommitted changes in $claude"
      return 0
    fi
  fi
  [ -e "$claude" ] && existed=1

  entire enable --local --yes --agent claude-code \
    --checkpoint-remote "$remote" --telemetry=false >/dev/null

  if [ "$tracked" = 1 ]; then
    git checkout -- "$claude"
  elif [ "$existed" = 0 ]; then
    rm -f "$claude"
    rmdir .claude 2>/dev/null || true
  fi

  local s=.entire/settings.local.json
  jq '.commit_linking = "always" | .sign_checkpoint_commits = false' "$s" >"$s.tmp" && mv "$s.tmp" "$s"

  local hook
  hook="$(git rev-parse --path-format=absolute --git-common-dir)/hooks/post-checkout"
  if [ ! -e "$hook" ] || grep -qF "$marker" "$hook"; then
    post_checkout_hook >"$hook" && chmod +x "$hook"
  else
    echo "warn $dir: existing post-checkout hook kept; new worktrees need a re-run"
  fi

  git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r wt; do
    [ "$wt" = "$(pwd -P)" ] && continue
    [ -f "$wt/.entire/settings.local.json" ] && continue
    mkdir -p "$wt/.entire" && cp .entire/settings.local.json .entire/.gitignore "$wt/.entire/"
  done
  echo "enabled $dir"
}

find "$root" -maxdepth 4 -name node_modules -prune -o -name .git -print | sort | while read -r g; do
  d=$(dirname "$g")
  # A worktree's .git file points into <common>/worktrees/; its clone covers it.
  [ -f "$g" ] && grep -q '/worktrees/' "$g" && continue
  case "$(git -C "$d" remote get-url origin 2>/dev/null)" in
    *github.com[:/]trusk-official/*) ;;
    *) continue ;;
  esac
  if [ "$apply" = 1 ]; then
    (enable_clone "$d") || echo "FAILED $d"
  else
    echo "would enable $d"
  fi
done
[ "$apply" = 1 ] || echo "dry run: pass --apply to enable"
