{ config, pkgs, lib, ... }:
# `claude-mtg` — the Hermes agent's MTG Commander skills as a terminal CLI, with
# everything else cut off: its own config dir (no shared skills, hooks, plugins,
# global CLAUDE.md or history), one MCP, no bundled skills, and no shell or web
# tools — the skills require every card/price/legality fact to come from the MCP.
#
# Skills live in shared/mtg-skills/, shared with Hermes but deliberately outside
# shared/skills/, which home/claude.nix auto-wires into every general agent.
let
  configDir = "${config.home.homeDirectory}/.claude-mtg";

  mcpConfig = pkgs.writeText "claude-mtg-mcp.json" (
    builtins.toJSON {
      # `pkgs.mtg-mcp` comes from the repo overlay (pkgs/overlay.nix) — the same
      # eval Hermes uses on the rpi5 (rpi5/hermes/hermes.nix).
      mcpServers.mtg.command = lib.getExe pkgs.mtg-mcp;
    }
  );

  settings = pkgs.writeText "claude-mtg-settings.json" (
    builtins.toJSON {
      # No ANTHROPIC_BASE_URL: it comes from the wrapper default in
      # home/claude.nix, which this execs — and putting it here would make it
      # unoverridable (a settings env entry beats the process environment).
      model = "opus[1m]";
      tui = "fullscreen";
      # Bundled skills (/init, /review, /run, …) ship inside the binary, so a
      # clean config dir does NOT drop them. User skills are unaffected.
      disableBundledSkills = true;
      permissions = {
        allow = [ "mcp__mtg" "Read(*)" "Glob(*)" "Grep(*)" "Write(*)" "Edit(*)" "Skill" "TodoWrite" ];
        deny = [ "Bash(*)" "WebFetch(*)" "WebSearch(*)" "Task(*)" ];
      };
    }
  );
in
{
  # Whole-directory symlink, NOT the skill-tree builder: a store-dir symlink
  # already delivers each skill's references/, so there is no defect to fix here
  # and nothing needs to write into this dir.
  home.file.".claude-mtg/skills".source = ../shared/mtg-skills;

  home.packages = [
    (pkgs.writeShellScriptBin "claude-mtg" ''
      set -eu
      export CLAUDE_CONFIG_DIR="${configDir}"
      # A custom config dir namespaces the credential store to
      # `Claude Code-credentials-<sha256(dir)[0:8]>`, so the CLI reads as logged
      # out despite a valid token. Empty (not unset) = use the default slot.
      export CLAUDE_SECURESTORAGE_CONFIG_DIR=""
      ws="''${CLAUDE_MTG_WORKSPACE:-${configDir}/workspace}"
      mkdir -p "$ws"
      cd "$ws" # no repo's CLAUDE.md gets auto-loaded, scratch files land here
      exec ${config.programs.claude-code.package}/bin/claude \
        --strict-mcp-config --mcp-config ${mcpConfig} \
        --settings ${settings} --setting-sources user \
        --append-system-prompt 'You are a Magic: The Gathering Commander assistant. Load the mtg-commander-deckbuilding skill to build, upgrade or validate a deck, and mtg-commander-strategy to pilot a finished one. Every card, price, legality and rules fact must come from the mcp__mtg__* tools; there is no shell or web access.' \
        "$@"
    '')
  ];
}
