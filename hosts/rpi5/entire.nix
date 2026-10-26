# Entire (agent-session checkpoints). Per-repo config (.entire/settings.json, the
# Claude hooks) is committed in each repo. Codex hooks live here: Codex runs a
# repo's hooks only after an interactive /hooks approval keyed by path, and T3
# drives every thread non-interactively in a fresh worktree. Hooks in /etc/codex
# (Codex's system layer) need no approval.
{ pkgs, ... }:
let
  # No Secret Service on the Pi: the default keyring store fails with "The name
  # is not activatable", so login-backed commands (activity, repo, explain
  # --repo) break. Wrapped rather than a session variable so hooks run by
  # systemd user units (T3, claude-rc) get it too.
  entire = pkgs.symlinkJoin {
    name = "entire-${pkgs.unstablePkgs.entire.version}";
    paths = [ pkgs.unstablePkgs.entire ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/entire --set-default ENTIRE_TOKEN_STORE file
    '';
  };
in
{
  environment.systemPackages = [ entire ];

  # From `entire agent add codex` (0.11.5); exits quietly where Entire is off.
  environment.etc."codex/hooks.json".source = ../../shared/entire/codex-hooks.json;
}
