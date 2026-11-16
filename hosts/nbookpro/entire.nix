# Entire for Trusk work: every trusk-official clone keeps its checkpoints in its
# own repo, and no Entire file is committed to those shared repos. So the agent
# hooks are machine-wide here, and per-clone settings come from
# `entire-trusk-enable` (home.nix).
{ pkgs, ... }:
let
  claudeManaged = "/Library/Application Support/ClaudeCode/managed-settings.d";

  hubHook = pkgs.writeShellApplication {
    name = "entire-hub-hook";
    runtimeInputs = [
      pkgs.git
      pkgs.jq
    ];
    text = builtins.readFile ./scripts/entire-hub-hook.sh;
  };
in
{
  # Codex's system layer: hooks here run without a /hooks approval.
  # Interpolated: a bare path links into the repo's -source with no store
  # reference, so a Cachix-deployed closure lacks it.
  environment.etc."codex/hooks.json".source = "${../../shared/entire/codex-hooks.json}";

  # The Claude hooks live in home/dotfiles/claude-settings.json and call
  # entire-hub-hook here, so sessions started in ~/MyDocuments/TRUSK are
  # captured in the clones they touch. Not in managed settings: the
  # Trusk org's server-managed settings win, and Claude Code then ignores
  # managed-settings.d entirely. Old file removed so it can't fire twice.
  environment.systemPackages = [ hubHook ];
  system.activationScripts.postActivation.text = ''
    rm -f "${claudeManaged}/entire.json"
  '';
}
