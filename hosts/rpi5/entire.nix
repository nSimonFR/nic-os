# Entire (agent-session checkpoints). Per-repo config (.entire/settings.json, the
# Claude hooks) is committed in each repo. Codex hooks live here: Codex runs a
# repo's hooks only after an interactive /hooks approval keyed by path, and T3
# drives every thread non-interactively in a fresh worktree. Hooks in /etc/codex
# (Codex's system layer) need no approval.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.unstablePkgs.entire ];

  # From `entire agent add codex` (0.11.5); exits quietly where Entire is off.
  environment.etc."codex/hooks.json".source = ./entire-codex-hooks.json;
}
