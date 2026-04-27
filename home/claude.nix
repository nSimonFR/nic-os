{
  config,
  pkgs,
  unstablePkgs,
  telegramChatId,
  ...
}:
let
  notifyScript = (import ./lib/telegram-notify.nix { inherit pkgs telegramChatId; }) {
    name = "claude";
    header = "🤖 *Claude Code*";
    stateDir = "/tmp/claude-notify-state";
    tokenPath = config.age.secrets.telegram-bot-token.path;
  };
  claudeCodePkg = unstablePkgs.claude-code.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
    postFixup = (old.postFixup or "") + ''
      wrapProgram $out/bin/claude \
        --set GIT_SSH_COMMAND "ssh -i ~/.ssh/ai_id_ed25519 -o IdentityAgent=none" \
        --set GIT_AUTHOR_NAME "nSimonFR-ai" \
        --set GIT_AUTHOR_EMAIL "265587706+nSimonFR-ai@users.noreply.github.com" \
        --set GIT_COMMITTER_NAME "nSimonFR-ai" \
        --set GIT_COMMITTER_EMAIL "265587706+nSimonFR-ai@users.noreply.github.com" \
        --run 'export GH_TOKEN="$(gh auth token --user nSimonFR-ai 2>/dev/null || true)"' \
        --set GITHUB_TOKEN ""
    '';
  });
in
{
  programs.claude-code = {
    enable = true;
    package = claudeCodePkg;

    # Settings delivered as a writable file via mkOutOfStoreSymlink
    # (points to the repo checkout, not the Nix store) so Claude Code
    # can update them at runtime (e.g. /voice toggle).
    # Baseline: home/dotfiles/claude-settings.json
  };

  # Writable settings.json — symlinked to the repo checkout
  home.file.".claude/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/claude-settings.json";

  # Stable path for the Telegram notify hook so the settings JSON
  # doesn't need to embed a Nix store path that changes on rebuild.
  home.file.".claude/hooks/telegram-notify" = {
    source = notifyScript;
    executable = true;
  };

  # Wrapper for `claude remote-control` that bypasses the HM-generated
  # --mcp-config wrapper (its variadic <configs...> arg swallows subcommands).
  # Uses the overrideAttrs package directly (has env vars, no --mcp-config).
  home.file.".claude/bin/claude-rc" = {
    executable = true;
    source = pkgs.writeShellScript "claude-rc" ''
      exec "${claudeCodePkg}/bin/claude" remote-control "$@"
    '';
  };

  # LLM Wiki slash commands — single source of truth in
  # rpi5/picoclaw/skills/wiki-*/SKILL.md so PicoClaw and Claude Code use the
  # same prompts. PicoClaw frontmatter (name/description/metadata) is benign
  # for Claude Code, which only reads `description`.
  home.file.".claude/commands/wiki-ingest.md".source =
    ../rpi5/picoclaw/skills/wiki-ingest/SKILL.md;
  home.file.".claude/commands/wiki-process.md".source =
    ../rpi5/picoclaw/skills/wiki-process/SKILL.md;
  home.file.".claude/commands/wiki-lint.md".source =
    ../rpi5/picoclaw/skills/wiki-lint/SKILL.md;

}
