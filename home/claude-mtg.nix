{
  config,
  pkgs,
  lib,
  ...
}:
# `claude-mtg` — a single-purpose Magic: The Gathering CLI built on Claude Code.
#
# Same MTG Commander brain as the Hermes Telegram agent (the two skills in
# shared/mtg-skills/ + the mtg-mcp server), but reachable from a terminal and
# with EVERYTHING ELSE CUT OFF. Concretely, versus the normal `claude`:
#
#   - Config dir is ~/.claude-mtg (CLAUDE_CONFIG_DIR), NOT ~/.claude. That alone
#     drops the 8 shared skills, the telegram skill, the plugin marketplaces,
#     every hook (notify/memory-sync/bash-history/wakatime/rtk), the global
#     CLAUDE.md and the whole session/memory history — none of them are read
#     from a different config dir.
#   - `--strict-mcp-config --mcp-config` with an mtg-only file: no Linear,
#     GitHub, Miro, metabase, affine, toolhive, steampipe. Just mcp__mtg__*.
#   - `--setting-sources user` so the cwd's .claude/settings.json (and its
#     .local.json) can't inject project permissions/hooks either.
#   - Starts in ~/.claude-mtg/workspace, so no repo's CLAUDE.md is auto-loaded
#     and deck scratch files land somewhere harmless. Override with
#     CLAUDE_MTG_WORKSPACE=/some/dir claude-mtg.
#   - Bash/WebFetch/WebSearch/subagents are denied outright: the skills mandate
#     that all card, price, rules and deck data comes from the MCP, never from
#     direct Scryfall/EDHREC/Moxfield calls or scripts. Read/Write/Edit stay so
#     it can read its own references/ and export a decklist on request.
#
# The Hermes agent keeps its own copy of the same skills (rpi5/hermes/hermes.nix
# rsyncs shared/mtg-skills into ~/.hermes/skills/mtg/); this module is the local
# counterpart. Deliberately NOT in shared/skills/ — home/claude.nix auto-wires
# everything there into all four general-purpose agents, and these belong only
# to the two MTG surfaces.
let
  mtgMcp = pkgs.callPackage ../pkgs/mtg-mcp.nix { };

  configDir = "${config.home.homeDirectory}/.claude-mtg";
  workspace = "${configDir}/workspace";

  skillsDir = ../shared/mtg-skills;
  skillNames = lib.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir skillsDir)
  );

  # MCP surface: exactly one stdio server, launched from the Nix store. Public
  # MTG data only, so no secrets/env are handed to the subprocess.
  mcpConfig = pkgs.writeText "claude-mtg-mcp.json" (
    builtins.toJSON { mcpServers.mtg.command = lib.getExe mtgMcp; }
  );

  # Passed with --settings (not written into ~/.claude-mtg/settings.json) so
  # Claude Code keeps full ownership of that file for its own runtime state
  # (theme, onboarding) without fighting a read-only store symlink.
  #
  # ANTHROPIC_BASE_URL mirrors home/dotfiles/claude-settings.json: requests keep
  # going through the Aperture gate like every other agent in the fleet. It is
  # repeated here because ~/.claude/settings.json is out of scope by design.
  settingsFile = pkgs.writeText "claude-mtg-settings.json" (builtins.toJSON {
    env.ANTHROPIC_BASE_URL = "https://ai.gate-mintaka.ts.net";
    model = "opus[1m]";
    tui = "fullscreen";
    # Drop Claude Code's own bundled skills (/init, /review, /run, /schedule,
    # /loop, claude-api, security-review, …). They ship inside the binary, so a
    # clean config dir does NOT get rid of them — this setting does. User skills
    # (the two MTG ones) are explicitly unaffected. Equivalent env var:
    # CLAUDE_CODE_DISABLE_BUNDLED_SKILLS=1.
    disableBundledSkills = true;
    permissions = {
      # Server-level allow: every mcp__mtg__* tool is a read-only public-data
      # lookup, so prompting on each one would only add friction.
      allow = [
        "mcp__mtg"
        "Read(*)"
        "Glob(*)"
        "Grep(*)"
        "Write(*)"
        "Edit(*)"
        "Skill"
        "TodoWrite"
      ];
      # deny wins over allow at every scope and can't be granted interactively —
      # this is the actual enforcement of "MCP data only, no side channels".
      deny = [
        "Bash(*)"
        "WebFetch(*)"
        "WebSearch(*)"
        "Task(*)"
        "Agent"
      ];
    };
  });

  claudeMtg = pkgs.writeShellScriptBin "claude-mtg" ''
    set -eu
    export CLAUDE_CONFIG_DIR="${configDir}"
    # Share the main login instead of demanding a second /login. Claude Code
    # namespaces its credential store per config dir: the Keychain service is
    # `Claude Code-credentials-<sha256(dir)[0:8]>` whenever CLAUDE_CONFIG_DIR is
    # set, so ~/.claude-mtg would look logged out despite a valid token sitting
    # in the login Keychain. CLAUDE_SECURESTORAGE_CONFIG_DIR is the documented
    # override, and an EMPTY value is the "use the default, unsuffixed name"
    # signal — verified against the 2.1.220 binary. Isolation is unaffected:
    # this only picks the credential slot, nothing else.
    export CLAUDE_SECURESTORAGE_CONFIG_DIR=""
    ws="''${CLAUDE_MTG_WORKSPACE:-${workspace}}"
    mkdir -p "$ws"
    cd "$ws"
    exec ${config.programs.claude-code.package}/bin/claude \
      --strict-mcp-config \
      --mcp-config ${mcpConfig} \
      --settings ${settingsFile} \
      --setting-sources user \
      "$@"
  '';
in
{
  home.packages = [ claudeMtg ];

  home.file =
    # ~/.claude-mtg/skills/<name>/ — one entry per directory in
    # shared/mtg-skills, so adding a third MTG skill is just a new directory.
    lib.listToAttrs (
      map (name: {
        name = ".claude-mtg/skills/${name}";
        value.source = "${skillsDir}/${name}";
      }) skillNames
    )
    // {
      # Auto-loaded because the wrapper starts the session in this directory —
      # gives the CLI its identity without an --append-system-prompt blob.
      ".claude-mtg/workspace/CLAUDE.md".source = ./claude-mtg/CLAUDE.md;
    };

  # A fresh CLAUDE_CONFIG_DIR starts logged out: on macOS the OAuth token itself
  # lives in the login Keychain (shared across config dirs), but the CLI gates on
  # `oauthAccount` in <config dir>/.claude.json, which a new dir doesn't have —
  # so `claude-mtg` would demand its own /login. Seed just the account identity
  # from the main config; on Linux, where credentials are a file rather than a
  # Keychain item, link that too. Idempotent, and re-runs on every switch so a
  # re-login in ~/.claude propagates. Everything else in .claude.json (history,
  # project list, MCP entries, onboarding state) stays separate.
  home.activation.claude-mtg-auth = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    src="$HOME/.claude.json"
    dst="${configDir}/.claude.json"
    if [ -f "$src" ]; then
      mkdir -p "${configDir}"
      [ -f "$dst" ] || echo '{}' > "$dst"
      ${pkgs.jq}/bin/jq -s \
        '.[1] * (.[0] | {oauthAccount, hasCompletedOnboarding}
                      | with_entries(select(.value != null)))' \
        "$src" "$dst" > "$dst.tmp" && mv "$dst.tmp" "$dst"
    fi
    if [ -f "$HOME/.claude/.credentials.json" ] && [ ! -e "${configDir}/.credentials.json" ]; then
      ln -s "$HOME/.claude/.credentials.json" "${configDir}/.credentials.json"
    fi
  '';
}
