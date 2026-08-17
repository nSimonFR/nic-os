#!/usr/bin/env bash
# PostToolUse hook: emit a Wakapi heartbeat tagged as the Claude Code
# editor. Wakapi dedupes heartbeats within ~2 min, so firing on every tool
# use is safe and lets time-on-task reflect real Claude activity.
# Always exits 0 — must not block Claude Code.
set +e

if ! command -v wakatime-cli >/dev/null 2>&1; then
  exit 0
fi

# Best-effort cwd from the hook input; fall back to the actual pwd.
input=$(cat 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"

# Project name: the *main* repo, not the checkout directory. Claude Code
# worktrees live at <repo>/.claude/worktrees/bridge-cse_<24-char-session-id>,
# so a bare `basename "$cwd"` filed every bridge session under its own
# throwaway project. --git-common-dir points at the shared <repo>/.git even
# from a linked worktree, so its parent is the repo root in both cases.
gitdir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
case "$gitdir" in
  */.git) project=$(basename "${gitdir%/.git}") ;;
  *) project=$(basename "$cwd") ;;
esac
[ -z "$project" ] && project=$(basename "$cwd")

# Keep the worktrees distinguishable one level down: wakatime-cli does not
# auto-detect a branch for --entity-type app, so pass it explicitly.
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)

# Entity must be a path-ish thing for wakatime-cli to accept it as a file;
# use the project root so the heartbeat groups under that project.
#
# --plugin MUST end in "<editor>-wakatime/<ver>": wakapi's user-agent parser
# (utils/http.go userAgentPattern) only extracts an editor when the UA ends
# with that exact suffix. The old "claude-code-wrapper/1.0" failed the regex
# entirely, so wakapi filed these heartbeats under a blank editor + blank OS
# ("Unknown"). "Claude-Code-wakatime/1.0" parses as editor "Claude-Code".
wakatime-cli \
  --write \
  --entity "$cwd" \
  --entity-type app \
  --plugin "Claude-Code-wakatime/1.0" \
  --project "$project" \
  ${branch:+--alternate-branch "$branch"} \
  --language "Claude" \
  --category "ai coding" \
  >/dev/null 2>&1

exit 0
