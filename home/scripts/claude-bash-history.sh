#!/usr/bin/env bash
# PostToolUse hook for the Bash tool. Appends each command to a private log
# (~/.claude/bash_history.log) in zsh EXTENDED_HISTORY format. Lives outside
# ~/.zsh_history so atuin's zsh-history importer never sees these entries.
# Always exits 0 — must not block Claude Code.
LOG="${HOME}/.claude/bash_history.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$cmd" ] && exit 0
ts=$(date +%s)
escaped=${cmd//$'\n'/$'\\\n'}
printf ': %s:0;%s\n' "$ts" "$escaped" >> "$LOG" 2>/dev/null
exit 0
