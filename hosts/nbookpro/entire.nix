# Entire for Trusk work: every trusk-official clone keeps its checkpoints in its
# own repo, and no Entire file is committed to those shared repos. So the agent
# hooks are machine-wide here, and per-clone settings come from
# `entire-trusk-enable` (home.nix).
{ pkgs, lib, ... }:
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
  # Each Entire hook goes through entire-hub-hook, so sessions started in
  # ~/MyDocuments/TRUSK (not a repo) are captured in the clones they touch.
  hookName = cmd: builtins.head (builtins.match ".*claude-code ([a-z-]+).*" cmd);
  base = lib.importJSON ../../shared/entire/claude-hooks.json;
  hook = name: {
    type = "command";
    command = "${lib.getExe hubHook} ${name}";
  };
  routed = lib.mapAttrs (
    _: map (m: m // { hooks = map (h: h // hook (hookName h.command)) m.hooks; })
  ) base.hooks;
  claudeHooks = pkgs.writeText "entire-claude-hooks.json" (
    builtins.toJSON {
      hooks = routed // {
        PreToolUse = routed.PreToolUse ++ [
          {
            matcher = "Edit|Write|MultiEdit|NotebookEdit|Bash";
            hooks = [ (hook "route" // { timeout = 30; }) ];
          }
        ];
      };
    }
  );
in
{
  # Codex's system layer: hooks here run without a /hooks approval.
  # Interpolated: a bare path links into the repo's -source with no store
  # reference, so a Cachix-deployed closure lacks it.
  environment.etc."codex/hooks.json".source = "${../../shared/entire/codex-hooks.json}";

  # Claude Code's managed settings: these hooks run in every session, T3 and
  # headless included, without an approval prompt (checked on 2.1.x).
  system.activationScripts.postActivation.text = ''
    mkdir -p "${claudeManaged}"
    ln -sfn ${claudeHooks} "${claudeManaged}/entire.json"
  '';
}
