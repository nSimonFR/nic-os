# post-checkout hook (managed by claude-remote-control.nix, symlinked into
# .git/hooks/post-checkout at bridge start; also re-run over existing worktrees
# by prepConfigScript on every bridge start).
#
# When the Remote Control bridge spawns an isolated worktree for a mobile /
# claude.ai session, that worker inherits the bridge's isolated CLAUDE_CONFIG_DIR
# (~/.claude-rc), whose settings.json forces ANTHROPIC_BASE_URL=api.anthropic.com
# to satisfy the Remote Control guard. Workers themselves do NOT run that guard,
# so we re-gate them here: point the base URL back at the Aperture gate,
# restoring observability for remote-control session traffic.
#
# The bridge's own control-plane stays direct, and must: the guard is still live
# in claude-code 2.1.220 (`fbr="Remote Control is only available when using
# Claude via api.anthropic.com."` in bin/.claude-wrapped), so dropping the forced
# URL there kills the bridge rather than gating it.
#
# _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL rides along because gating the worker
# costs it the 1M context window. Opus 5 and Sonnet 5 carry
# `context:{window:1e6,native_1m:true}` in the client's model registry and need no
# beta header for it, but the client only credits native_1m when it believes it is
# talking to Anthropic directly: `IM()` requires `Yd()`, and `Yd()` is
# `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL || host === api.anthropic.com` read
# from process.env — which a settings `env` entry becomes. So the moment this hook
# points the base URL at the gate, every bridge session silently drops to 200k and
# auto-compacts at ~167k (measured: 120 compact_boundary records across the
# 2026-08-18 sessions, every one of them 166–170k). Setting the flag restores 1m
# with the same `claude-opus-5` the bridge sends; the `[1m]` model alias cannot be
# used here because Remote Control's session_context.model overrides settings.json.
# Verified A/B on 2.1.220 with `claude -p /context --model claude-opus-5`:
# gate URL alone → "1.6k / 200k", gate URL + flag → "14.4k / 1m".
#
# It cannot leak into the guard: claude-code checks Remote Control eligibility
# with the raw base-URL test, and says so in as many words —
# "(_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL does not apply to Remote Control.)"
# The flag only affects first-party feature detection inside the worker, which is
# the truth here: the gate proxies to api.anthropic.com.
#
# Writes settings.LOCAL.json, not settings.json. Both reasons are load-bearing:
#
#   - nic-os COMMITS .claude/settings.json (MCP denies, credential guard hooks),
#     so it exists in every worktree the bridge creates. The previous version of
#     this hook bailed on that file rather than clobber it — which meant the gate
#     was silently never applied to a single nic-os worker. Every bridge session
#     went straight to api.anthropic.com, and in the 31h before this fix Aperture
#     held zero of them: only the 25/30-min claude-token-refresh haiku pings.
#     A repo that commits project settings disabled the whole mechanism.
#   - local scope outranks user scope, so it beats the bridge's forced URL —
#     which a project-scope file would NOT reliably do — and
#     .claude/settings.local.json is gitignored, so writing it does not leave
#     every bridge worktree with a dirty tracked file.
#
# Guarded by CLAUDE_CONFIG_DIR so it is a fast no-op for the user's normal
# checkouts and for other agents' worktrees.

case "${CLAUDE_CONFIG_DIR:-}" in
  */.claude-rc) ;;
  *) exit 0 ;;
esac

top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
case "$top" in
  */.claude/worktrees/*) ;;
  *) exit 0 ;;
esac

# The gate URL now lives as a wrapper default in home/claude.nix, not in
# settings.json (a settings env entry cannot be overridden, which broke Remote
# Control). Still read settings.json first in case a host pins it there, and
# otherwise use the known gate host — the normal path since that move.
gate=$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
[ -n "$gate" ] || gate="https://ai.gate-mintaka.ts.net"

mkdir -p "$top/.claude"
settings="$top/.claude/settings.local.json"

# Merge rather than clobber: a worker may have its own local settings, and this
# hook fires on every checkout in the worktree plus every bridge start, not just
# at worktree creation. Without jq we cannot merge safely, so leave an existing
# file alone rather than destroy its other keys.
if [ -s "$settings" ]; then
  command -v jq >/dev/null 2>&1 || exit 0
  tmp="$settings.tmp.$$"
  if jq --arg gate "$gate" '.env.ANTHROPIC_BASE_URL = $gate
      | .env._CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1"' \
      "$settings" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"
  fi
else
  printf '{"env":{"ANTHROPIC_BASE_URL":"%s","_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL":"1"}}\n' \
    "$gate" >"$settings"
fi
exit 0
