# Entire for Trusk work: checkpoints from every trusk-official clone go to the
# private nSimonFR/trusk-checkpoints, and nothing is committed to those shared
# repos. So the agent hooks are machine-wide here, and per-clone settings come
# from `entire-trusk-enable` (home.nix).
{ ... }:
let
  claudeManaged = "/Library/Application Support/ClaudeCode/managed-settings.d";
in
{
  # Codex's system layer: hooks here run without a /hooks approval.
  environment.etc."codex/hooks.json".source = ../../shared/entire/codex-hooks.json;

  # Claude Code's managed settings: these hooks run in every session, T3 and
  # headless included, without an approval prompt (checked on 2.1.x).
  system.activationScripts.postActivation.text = ''
    mkdir -p "${claudeManaged}"
    ln -sfn ${../../shared/entire/claude-hooks.json} "${claudeManaged}/entire.json"
  '';
}
