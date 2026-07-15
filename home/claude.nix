{
  config,
  pkgs,
  lib,
  unstablePkgs,
  telegramChatId,
  ...
}:
let
  # Shared skills live under ../shared/skills/ and are auto-discovered so
  # adding a new one is just a directory. Each skill is wired into all
  # four agents' skill loaders: Claude Code (~/.claude/skills/), Codex
  # (~/.codex/skills/), pi-coding-agent (~/.pi/agent/skills/), and
  # picoclaw (rpi5/picoclaw/picoclaw.nix merges them into its workspace).
  sharedSkillsDir = ../shared/skills;
  sharedSkillNames = lib.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir sharedSkillsDir)
  );

  # Skills that should ALSO be exposed as Claude Code slash commands
  # (`/wiki-ingest`, etc.). The SKILL.md frontmatter is benign for
  # Claude Code, which only reads the `description` field.
  claudeSlashCommandSkills = [ "wiki-ingest" "wiki-process" "wiki-lint" ];

  sharedSkillFiles = lib.listToAttrs (lib.concatMap (name: [
    {
      name = ".claude/skills/${name}/SKILL.md";
      value.source = "${sharedSkillsDir}/${name}/SKILL.md";
    }
    {
      name = ".codex/skills/${name}/SKILL.md";
      value.source = "${sharedSkillsDir}/${name}/SKILL.md";
    }
    {
      name = ".pi/agent/skills/${name}/SKILL.md";
      value.source = "${sharedSkillsDir}/${name}/SKILL.md";
    }
  ]) sharedSkillNames);

  claudeCommandFiles = lib.listToAttrs (map (name: {
    name = ".claude/commands/${name}.md";
    value.source = "${sharedSkillsDir}/${name}/SKILL.md";
  }) claudeSlashCommandSkills);

  claudeCodePkg = unstablePkgs.claude-code.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
    # The vendored vendor/ripgrep/arm64-linux/rg in claude-code's npm package
    # ships a jemalloc compiled for 4K pages and SIGABRTs on the rpi5's 16K-page
    # kernel ("<jemalloc>: Unsupported system page size"). Force cli.js onto the
    # system rg via USE_BUILTIN_RIPGREP=0 + PATH prefix.
    postFixup = (old.postFixup or "") + ''
      wrapProgram $out/bin/claude \
        --prefix PATH : /run/wrappers/bin \
        --prefix PATH : ${pkgs.ripgrep}/bin \
        --set USE_BUILTIN_RIPGREP 0 \
        --set GIT_SSH_COMMAND "ssh -i ~/.ssh/ai_id_ed25519 -o IdentityAgent=none" \
        --set GIT_AUTHOR_NAME "nSimonFR-ai" \
        --set GIT_AUTHOR_EMAIL "265587706+nSimonFR-ai@users.noreply.github.com" \
        --set GIT_COMMITTER_NAME "nSimonFR-ai" \
        --set GIT_COMMITTER_EMAIL "265587706+nSimonFR-ai@users.noreply.github.com" \
        --run 'export GH_TOKEN="$(gh auth token --user nSimonFR-ai 2>/dev/null || true)"' \
        --set GITHUB_TOKEN ""
    '';
  });

  # claude-auto-retry (https://github.com/cheapestinference/claude-auto-retry):
  # watches an interactive Claude session for a usage-cap message, waits out the
  # reset window (timezone-aware), and auto-sends `continue` via tmux send-keys.
  # The published npm package is dependency-free pure ESM, so we just vendor the
  # tarball and wrap its entrypoints with node — no buildNpmPackage needed.
  # Exposes two bins: `claude-auto-retry` (status/logs/version CLI) and
  # `claude-car-launcher` (the wrapper the `claude` shell function calls).
  # PATH is prefixed with tmux/procps/which so the forked monitor finds them
  # regardless of the caller's environment.
  claudeAutoRetry = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "claude-auto-retry";
    # >=0.4 detects Claude Code's current hard-cap wording "You've hit your
    # session/weekly limit" (0.2.2's LIMIT_PATTERNS required `your`/`the`
    # adjacent to `limit`, so the qualifier word broke detection and caps were
    # never auto-resumed). Fixed upstream, so no local pattern override needed.
    version = "0.5.1";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/claude-auto-retry/-/claude-auto-retry-${version}.tgz";
      hash = "sha256-tH4XxtjlTgvX5Ovp3d/U26m2uMjd9BozFmC6clMlt5s=";
    };
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/claude-auto-retry $out/bin
      cp -r . $out/share/claude-auto-retry/
      runtimePath=${lib.makeBinPath [ pkgs.tmux pkgs.procps pkgs.which ]}
      makeWrapper ${pkgs.nodejs}/bin/node $out/bin/claude-auto-retry \
        --add-flags $out/share/claude-auto-retry/bin/cli.js \
        --prefix PATH : "$runtimePath"
      makeWrapper ${pkgs.nodejs}/bin/node $out/bin/claude-car-launcher \
        --add-flags $out/share/claude-auto-retry/src/launcher.js \
        --prefix PATH : "$runtimePath"
      runHook postInstall
    '';
  };
in
{
  # claude-auto-retry CLI (`claude-auto-retry status|logs`) + the
  # `claude-car-launcher` the `claude` shell function routes through.
  home.packages = [ claudeAutoRetry ];

  programs.claude-code = {
    enable = true;
    package = claudeCodePkg;

    # Settings delivered as a writable file via mkOutOfStoreSymlink
    # (points to the repo checkout, not the Nix store) so Claude Code
    # can update them at runtime (e.g. /voice toggle).
    # Baseline: home/dotfiles/claude-settings.json
  };

  # All home-managed files are merged into one set: shared skills (auto-
  # discovered from shared/skills/), Claude slash commands (curated
  # subset), and Claude Code's own settings/hooks. Picoclaw picks up the
  # same shared skills via rpi5/picoclaw/picoclaw.nix.
  home.file = sharedSkillFiles // claudeCommandFiles // {
    # Claude-Code-only skill (NOT shared with codex/pi/picoclaw — picoclaw already
    # *is* the Telegram bot): how to post messages/photos to Telegram via the bot.
    ".claude/skills/telegram/SKILL.md".source = ./claude-skills/telegram/SKILL.md;

    # Writable settings.json — symlinked to the repo checkout so /voice etc.
    # can update it at runtime.
    ".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/claude-settings.json";

    # Keybindings — Enter submits, Shift+Enter inserts a newline. Symlinked to
    # the repo checkout (not the Nix store) so it stays hand-editable.
    # Baseline: home/dotfiles/claude-keybindings.json
    ".claude/keybindings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/claude-keybindings.json";

    # Trusk infra notes — scoped to ~/MyDocuments/TRUSK/. CLAUDE.md is loaded by
    # walking UP the directory tree from cwd, so this file loads for every Trusk
    # repo/subfolder and nowhere else (keeps ~6k tokens out of non-Trusk sessions).
    # Writable out-of-store symlink so the "keep it fresh" workflow edits the repo
    # file live, no rebuild needed.
    "MyDocuments/TRUSK/CLAUDE.md".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/trusk-CLAUDE.md";

    # Unified Telegram notify gate (see home/scripts/claude-notify.sh). Wired
    # under three hook events in claude-settings.json: UserPromptSubmit
    # (`activity`), Notification (`notification`, idle-gated), and
    # PostToolUse/PushNotification (`push`, always through). Shared with the
    # remote-control bridge via the ~/.claude-rc/hooks symlink.
    ".claude/hooks/claude-notify" = {
      source = ./scripts/claude-notify.sh;
      executable = true;
    };

    # Wrapper for `claude remote-control` that bypasses the HM-generated
    # --mcp-config wrapper (its variadic <configs...> arg swallows subcommands).
    ".claude/bin/claude-rc" = {
      executable = true;
      source = pkgs.writeShellScript "claude-rc" ''
        exec "${claudeCodePkg}/bin/claude" remote-control "$@"
      '';
    };

    # claude-auto-retry config (read at runtime by the monitor). marginSeconds
    # waits a bit past the parsed reset; fallbackWaitHours bounds the wait when
    # no reset time is parseable; retryMessage is what's sent via send-keys.
    ".claude-auto-retry.json".text = builtins.toJSON {
      maxRetries = 5;
      pollIntervalSeconds = 5;
      marginSeconds = 60;
      fallbackWaitHours = 5;
      retryMessage = "continue";
    };

    # PostToolUse hook: mirror writes under
    # ~/.claude/projects/-home-nsimon-nic-os/memory/ into AFFiNE
    # Wiki/Pages/Claude Memory/ via the affine-mcp HTTP bridge.
    ".claude/hooks/memory-sync" = {
      source = ./scripts/claude-memory-sync.py;
      executable = true;
    };

    # PostToolUse hook on Bash: register each command with atuin under a
    # separate host (ATUIN_HOST_NAME=claude-code) plus a sentinel cwd
    # (~/.claude/bash) so commands sync across devices but stay out of the
    # human's host-/workspace-filtered interactive recall (dotfiles/atuin.toml
    # uses filter_mode = "host" and workspace = true).
    ".claude/hooks/bash-history" = {
      source = ./scripts/claude-bash-history.sh;
      executable = true;
    };

    # PostToolUse hook: emit a Wakapi heartbeat for each tool use so Claude
    # Code time-on-task lands in WakaTime stats alongside editor activity.
    ".claude/hooks/wakatime" = {
      source = ./scripts/claude-wakatime.sh;
      executable = true;
    };
  } // lib.optionalAttrs pkgs.stdenv.isDarwin {
    # Trusk infra notes — only the Mac (nBookPro) has the Trusk repos under
    # ~/MyDocuments/TRUSK/. CLAUDE.md is loaded by walking UP the dir tree, so it
    # loads for every Trusk repo/subfolder and nowhere else. Gated off the Linux
    # hosts (BeAsT/rpi5), where it would otherwise create a stray/dangling symlink.
    # Writable out-of-store symlink so the "keep it fresh" workflow edits live.
    "MyDocuments/TRUSK/CLAUDE.md".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/trusk-CLAUDE.md";
  };

}
