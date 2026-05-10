#!/usr/bin/env bash
# PostToolUse hook for the Bash tool. Pushes each command into atuin under
# sentinel cwd ~/.claude/bash so it syncs across devices and can be filtered
# with: atuin search --filter-mode global --cwd ~/.claude/bash
# (or excluded from normal recall by the same path).
# Always exits 0 — must not block Claude Code.
SENTINEL="${HOME}/.claude/bash"
SESSION_FILE="${HOME}/.claude/.atuin-session"
mkdir -p "$SENTINEL" 2>/dev/null

# Per-Claude-session UUID so all calls in one session group together.
if [ ! -s "$SESSION_FILE" ]; then
  atuin uuid > "$SESSION_FILE" 2>/dev/null || exit 0
fi
ATUIN_SESSION=$(cat "$SESSION_FILE" 2>/dev/null) || exit 0
[ -z "$ATUIN_SESSION" ] && exit 0
export ATUIN_SESSION

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$cmd" ] && exit 0

HID=$(cd "$SENTINEL" && atuin history start -- "$cmd" 2>/dev/null) || exit 0
[ -z "$HID" ] && exit 0
atuin history end --exit 0 "$HID" >/dev/null 2>&1
exit 0
