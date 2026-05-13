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

project=$(basename "$cwd")
# Entity must be a path-ish thing for wakatime-cli to accept it as a file;
# use the project root so the heartbeat groups under that project.
wakatime-cli \
  --write \
  --entity "$cwd" \
  --entity-type app \
  --plugin "claude-code-wrapper/1.0" \
  --project "$project" \
  --language "Claude" \
  >/dev/null 2>&1

exit 0
