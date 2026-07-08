#!/usr/bin/env bash
# PostToolUse hook for the Bash tool. Records each command Claude Code runs into
# atuin under a SEPARATE host (ATUIN_HOST_NAME=claude-code) plus a sentinel cwd
# (~/.claude/bash), so the commands still sync across devices yet stay out of the
# human's interactive recall. Both handles are needed because dotfiles/atuin.toml
# sets BOTH of these:
#   * filter_mode = "host" — up-arrow / default search only surface commands from
#     the CURRENT host, regardless of cwd. Recording Claude's commands under
#     "claude-code" (atuin stores the host column as "claude-code:<user>", see
#     get_host_user in atuin-client) keeps them off every real machine's
#     host-filtered recall. This is the fix for NSI-75.
#   * workspace = true — inside a git repo atuin filters to that repo's workspace
#     REGARDLESS of host, so a separate host alone would still leak if we recorded
#     the real cwd. The sentinel cwd (~/.claude/bash, not a git repo) keeps the
#     commands out of workspace-filtered recall too, so we keep it.
# The host is resolved client-side at record time (even with the sync daemon
# enabled, the client builds the History entry and ships it to the daemon), so
# exporting ATUIN_HOST_NAME here is sufficient.
# Retrieve Claude's commands explicitly, e.g.:
#   atuin search --filter-mode global --cwd ~/.claude/bash
# Always exits 0 — must not block Claude Code.
export ATUIN_HOST_NAME="claude-code"
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
