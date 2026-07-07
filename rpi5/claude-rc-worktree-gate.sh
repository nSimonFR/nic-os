# post-checkout hook (managed by claude-remote-control.nix, symlinked into
# .git/hooks/post-checkout at bridge start).
#
# When the Remote Control bridge spawns an isolated worktree for a mobile /
# claude.ai session, that worker inherits the bridge's isolated CLAUDE_CONFIG_DIR
# (~/.claude-rc), whose settings.json forces ANTHROPIC_BASE_URL=api.anthropic.com
# to satisfy the Remote Control guard. Workers themselves do NOT run that guard,
# so we re-gate them here: drop a project-level settings.json in the new worktree
# pointing the base URL back at the Aperture gate, restoring observability for
# remote-control session traffic. (The bridge's own control-plane stays direct.)
#
# Guarded by CLAUDE_CONFIG_DIR so it is a fast no-op for the user's normal
# checkouts and for other agents' worktrees. Never overwrites an existing
# settings.json.

case "${CLAUDE_CONFIG_DIR:-}" in
  */.claude-rc) ;;
  *) exit 0 ;;
esac

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
case "$top" in
  */.claude/worktrees/*) ;;
  *) exit 0 ;;
esac

[ -f "$top/.claude/settings.json" ] && exit 0

# Single source of truth = the real user settings' gate URL; fall back to the
# known gate host if jq or the file is unavailable.
gate=$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
[ -n "$gate" ] || gate="https://ai.gate-mintaka.ts.net"

mkdir -p "$top/.claude"
printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}\n' "$gate" > "$top/.claude/settings.json"
exit 0
