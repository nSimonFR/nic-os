# Kill stale bridge sessions and clean up orphaned worktrees.
# Works around: anthropics/claude-code#29313, #26725
#
# The bug: deleting a session from claude.ai/code does NOT signal the remote
# process to exit. The heartbeat API keeps returning state=active forever. So we
# detect staleness via conversation file inactivity (JSONL mtime) which is
# updated on every real user/assistant message — much more reliable than
# process age.
#
# Config comes from the unit's Environment= (claude-remote-control.nix); every
# var is required, so a missing one fails the unit rather than reaping against
# an empty path.
#
# Runs under writeShellApplication: set -euo pipefail + shellcheck. That is
# load-bearing here, not cosmetic — this script previously swallowed every
# failure (`2>/dev/null || rm -rf`) and then printed "no stale sessions found"
# regardless, so a reap that could not succeed retried silently every 30min for
# a week (336 ticks) with nothing to show for it. Failures are now counted and
# the run exits non-zero, which systemd-failed-alert turns into a Telegram
# message within 2min.

SESSIONS_DIR="${SESSIONS_DIR:?unset}"
PROJECTS_DIR="${PROJECTS_DIR:?unset}"
WORKTREES_DIR="${WORKTREES_DIR:?unset}"
REPO_DIR="${REPO_DIR:?unset}"
MAX_INACTIVITY="${MAX_INACTIVITY:?unset}"

now="$(date +%s)"
killed=0
reaped=0
stuck=0

for f in "$SESSIONS_DIR"/*.json; do
  [ -f "$f" ] || continue
  pid="$(basename "$f" .json)"
  entrypoint="$(jq -r '.entrypoint // ""' "$f")"

  # Only target bridge sessions (spawned by remote-control for web UI)
  [ "$entrypoint" = "sdk-cli" ] || continue

  # Skip if process is already dead — just clean up the file
  if [ ! -d "/proc/$pid" ]; then
    echo "removing stale session file for dead PID $pid"
    rm -f "$f"
    killed=$((killed + 1))
    continue
  fi

  # Find the conversation JSONL file to check last real activity
  session_id="$(jq -r '.sessionId // ""' "$f")"
  if [ -z "$session_id" ]; then continue; fi

  conv_file="$(find "$PROJECTS_DIR" -name "${session_id}.jsonl" -print -quit 2>/dev/null)"
  if [ -n "$conv_file" ] && [ -f "$conv_file" ]; then
    last_mod="$(stat -c %Y "$conv_file")"
    idle_sec=$(( now - last_mod ))
  else
    # No conversation file means it never got a message — use process age
    idle_sec="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')" || idle_sec=""
    if [ -z "$idle_sec" ]; then continue; fi
  fi

  if [ "$idle_sec" -gt "$MAX_INACTIVITY" ]; then
    idle_min=$(( idle_sec / 60 ))
    echo "killing stale bridge session PID=$pid sid=$session_id (inactive ${idle_min}min > $((MAX_INACTIVITY/60))min)"
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$f"
    killed=$((killed + 1))
  fi
done

# Clean up orphaned worktrees (bridge-cse_* dirs whose process is gone)
if [ -d "$WORKTREES_DIR" ]; then
  for wt in "$WORKTREES_DIR"/bridge-cse_*; do
    [ -d "$wt" ] || continue
    wt_name="$(basename "$wt")"
    # Check if any running claude process uses this worktree
    in_use=0
    for f in "$SESSIONS_DIR"/*.json; do
      [ -f "$f" ] || continue
      pid="$(basename "$f" .json)"
      [ -d "/proc/$pid" ] || continue
      cwd="$(jq -r '.cwd // ""' "$f")"
      case "$cwd" in
        *"$wt_name"*) in_use=1; break ;;
      esac
    done
    if [ "$in_use" = "0" ]; then
      # Preserve recently-active worktrees even with no live worker. A bridge
      # worker process only exists mid-turn, so an idle-but-resumable session
      # — and, right after a reboot, EVERY session until it is re-hosted — has
      # no live cwd here and would be reaped, which deletes the worktree and
      # freezes the session permanently (the app has nothing to spawn into).
      # Gate on the transcript JSONL mtime, the same 24h window the stale-
      # process loop above uses. Workers run with CLAUDE_CONFIG_DIR=~/.claude-rc
      # whose projects/ symlink points into $PROJECTS_DIR; the transcript dir
      # is the worktree path slugified (every non-alphanumeric char -> '-').
      slug="$(printf '%s' "$wt" | tr -c 'A-Za-z0-9' '-')"
      conv_dir="$PROJECTS_DIR/$slug"
      last_mod=0
      if [ -d "$conv_dir" ]; then
        # `|| last_mod=` and not a bare pipeline: head -1 closing the pipe can
        # SIGPIPE sort, and pipefail would abort the whole run on a worktree
        # that simply has many transcripts. Empty falls through to 0 below.
        last_mod="$(find "$conv_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@\n' 2>/dev/null \
          | cut -d. -f1 | sort -rn | head -1)" || last_mod=""
        if [ -z "$last_mod" ]; then last_mod=0; fi
      fi
      if [ "$last_mod" -gt 0 ] && [ "$(( now - last_mod ))" -le "$MAX_INACTIVITY" ]; then
        echo "preserving recently-active worktree: $wt_name (idle $(( (now - last_mod) / 60 ))min)"
        continue
      fi
      echo "removing orphaned worktree: $wt_name"
      # Unlock BEFORE removing. Every bridge worktree is locked at creation
      # (so a reboot can't let prune reap a resumable session), and
      # `worktree remove --force` REFUSES a locked worktree — it does not
      # override the lock. Without this unlock the command failed silently,
      # fell through to the `rm -rf`, and left the registration behind
      # forever.
      git -C "$REPO_DIR" worktree unlock "$wt" 2>/dev/null || true
      # stderr is NOT swallowed any more. Both of these legitimately fail —
      # `worktree remove` on a directory git has no registration for, `rm -rf`
      # on a subtree root left behind (a root-owned __pycache__ from a `sudo`
      # python run inside the checkout is the observed cause) — and hiding the
      # reason is what let the same reap fail 336 times unnoticed.
      if ! git -C "$REPO_DIR" worktree remove --force "$wt"; then
        rm -rf "$wt" || true
      fi
      if [ -e "$wt" ]; then
        stuck=$((stuck + 1))
        echo "ERROR: worktree survived removal: $wt" >&2
        # Redirect order matters: `>&2` must come BEFORE `2>/dev/null`, else it
        # duplicates the already-silenced fd and the listing goes to /dev/null.
        find "$wt" ! -user "$(id -un)" -printf '  undeletable (%u:%g): %p\n' >&2 2>/dev/null || true
        echo "  remedy: sudo rm -rf $wt" >&2
      else
        reaped=$((reaped + 1))
      fi
    fi
  done

  # Collect registrations whose directory is already gone. `worktree prune`
  # silently SKIPS locked entries, so any worktree that lost its directory
  # while still locked — every one removed by the rm -rf fallback above, plus
  # anything cleaned up by hand — stayed registered permanently. These had
  # accumulated to 356 orphans against 52 live worktrees (28MB of
  # .git/worktrees metadata, and 400+ branch refs kept alive because a
  # registration pins its branch). Unlock the dead ones first so prune can
  # actually do its job; live worktrees keep their locks.
  # Pure shell on purpose: awk is not in runtimeInputs.
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null \
    | while read -r wt_key wt_path; do
        [ "$wt_key" = "worktree" ] || continue
        if [ -d "$wt_path" ]; then continue; fi
        git -C "$REPO_DIR" worktree unlock "$wt_path" 2>/dev/null || true
      done
  git -C "$REPO_DIR" worktree prune 2>/dev/null || true
fi

# Report every counter, always. The old summary printed "no stale sessions
# found" whenever $killed was 0 — including runs that had just tried and failed
# to reap a worktree, which is how the stuck one stayed invisible.
echo "summary: sessions killed=$killed worktrees reaped=$reaped stuck=$stuck"
if [ "$stuck" -gt 0 ]; then
  echo "FAILED: $stuck worktree(s) could not be removed — see errors above" >&2
  exit 1
fi
