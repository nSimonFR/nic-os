# entire-brain-refresh — one Brain pass over a clean nic-os clone at origin/main.
# Brain refuses a dirty worktree, and ~/nic-os carries other sessions' edits.
# Its sessions come from the checkpoint refs, which live in the private repo.

dir=${ENTIRE_BRAIN_CLONE:-$HOME/.local/share/entire/nic-os}

if [ ! -d "$dir/.git" ]; then
  git clone --quiet https://github.com/nSimonFR/nic-os "$dir"
  entire-brain workspace remove default gh/nsimonfr/nic-os >/dev/null 2>&1 || true
  entire-brain workspace add default "$dir"
fi

git -C "$dir" fetch --quiet origin main
git -C "$dir" checkout --quiet --force --detach FETCH_HEAD
git -C "$dir" fetch --quiet https://github.com/nSimonFR/nic-os-checkpoints '+refs/entire/*:refs/entire/*'

exec entire-brain workspace watch --once --distill --model haiku --max-sessions 10
