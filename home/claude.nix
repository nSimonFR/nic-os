{
  config,
  pkgs,
  lib,
  unstablePkgs,
  telegramChatId,
  host,
  ...
}:
let
  # Which skills reach which surface (shared/skill-tree.nix defines skill /
  # lineage / surface). shared/skills is auto-discovered, so adding one is still
  # just a directory; Hermes selects the same lineage in hosts/rpi5/hermes/hermes.nix.
  # claude-skills is Claude-Code-only — the Hermes agent already IS the Telegram
  # bot. shared/mtg-skills is in neither, deliberately: MTG surfaces only.
  skillTree = import ../shared/skill-tree.nix { inherit lib; };
  sharedSkillsDir = ../shared/skills;

  # Skills that should ALSO be exposed as Claude Code slash commands
  # (`/wiki-ingest`, etc.). The SKILL.md frontmatter is benign for
  # Claude Code, which only reads the `description` field.
  claudeSlashCommandSkills = [ "wiki-ingest" "wiki-process" "wiki-lint" ];

  sharedSkillFiles =
    skillTree.homeFiles {
      targets = [ ".claude/skills" ".codex/skills" ".pi/agent/skills" ".dsh/skills" ];
      lineages = [ { source = sharedSkillsDir; } ];
    }
    // skillTree.homeFiles {
      targets = [ ".claude/skills" ];
      lineages = [ { source = ./claude-skills; } ];
    };

  claudeCommandFiles = lib.listToAttrs (map (name: {
    name = ".claude/commands/${name}.md";
    value.source = "${sharedSkillsDir}/${name}/SKILL.md";
  }) claudeSlashCommandSkills);

  # Batching seam (→ the :8088 aggregator). `source` is null because
  # claude-notify.sh distinguishes "Claude Code" from "Claude PushNotification"
  # per invocation and passes its own.
  agentNotify = (import ../shared/notify.nix { inherit pkgs; }).agent { name = "claude"; };

  # One-shot sender exposed to the `telegram` skill (home/claude-skills/telegram),
  # so the model calls a reviewed script instead of hand-rolling authenticated
  # HTTP with the bot token pasted into a shell command. Not notify.send: the
  # skill targets three different chats, so --chat is per call.
  telegramSend = pkgs.writeShellScriptBin "telegram-send" ''
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}''${PATH:+:$PATH}
    export TELEGRAM_CHAT_ID=''${TELEGRAM_CHAT_ID:-${toString telegramChatId}}
    exec ${pkgs.bash}/bin/bash ${../shared/scripts/telegram-send.sh} "$@"
  '';

  # NOTE on ANTHROPIC_BASE_URL (below): the Aperture gate URL is injected here as
  # a wrapper DEFAULT rather than in claude-settings.json's `env` block, where it
  # used to live. A settings-file `env` entry is applied by Claude Code over the
  # process environment, so it could not be overridden by a caller — not by a
  # shell prefix and not even by `--settings`. That silently disabled Remote
  # Control everywhere (it refuses to run unless the session talks to
  # api.anthropic.com) and made claude-local/claude-beast/claude-direct's env
  # prefixes no-ops. `--set-default` keeps identical coverage — every invocation,
  # including the rpi5's headless services and the second config dir, still gets
  # the gate — while letting an explicit `ANTHROPIC_BASE_URL=…` in front of the
  # command win. See home/dotfiles/zsh/aliases.zsh.
  # Built as a list rather than one backslash-continued heredoc so a host-gated
  # flag can be dropped without leaving a dangling continuation behind.
  claudeWrapperFlags =
    [ "--prefix PATH : /run/wrappers/bin" ]
    # The vendored vendor/ripgrep/arm64-linux/rg in claude-code's npm package
    # ships a jemalloc compiled for 4K pages and SIGABRTs on the rpi5's 16K-page
    # kernel ("<jemalloc>: Unsupported system page size"). Force cli.js onto the
    # system rg. This is a workaround for one host's kernel, so it is applied on
    # that host — BeAsT and the Mac are 4K-page and run the vendored binary
    # upstream ships and tests.
    ++ lib.optionals host.has16KPages [
      "--prefix PATH : ${pkgs.ripgrep}/bin"
      "--set USE_BUILTIN_RIPGREP 0"
    ]
    ++ [
      ''--set-default ANTHROPIC_BASE_URL "https://ai.gate-mintaka.ts.net"''
      ''--set GIT_SSH_COMMAND "ssh -i ~/.ssh/ai_id_ed25519 -o IdentityAgent=none"''
      ''--set GIT_AUTHOR_NAME "nSimonFR-ai"''
      ''--set GIT_AUTHOR_EMAIL "265587706+nSimonFR-ai@users.noreply.github.com"''
      ''--set GIT_COMMITTER_NAME "nSimonFR-ai"''
      ''--set GIT_COMMITTER_EMAIL "265587706+nSimonFR-ai@users.noreply.github.com"''
      "--run 'export GH_TOKEN=\"$(gh auth token --user nSimonFR-ai 2>/dev/null || true)\"'"
      ''--set GITHUB_TOKEN ""''
    ];

  claudeCodePkg = unstablePkgs.claude-code.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
    postFixup = (old.postFixup or "") + ''
      wrapProgram $out/bin/claude ${lib.concatStringsSep " " claudeWrapperFlags}
    '';
  });

in
{
  # `telegram-send` on PATH is the executable half of the `telegram` skill below.
  home.packages = [ telegramSend ];

  programs.claude-code = {
    enable = true;
    package = claudeCodePkg;

    # Settings delivered as a writable file via mkOutOfStoreSymlink
    # (points to the repo checkout, not the Nix store) so Claude Code
    # can update them at runtime (e.g. /voice toggle).
    # Baseline: home/dotfiles/claude-settings.json
  };

  # All home-managed files are merged into one set: the skill lineages selected
  # above (shared + Claude-only), Claude slash commands (curated subset), and
  # Claude Code's own settings/hooks. The Hermes agent picks up the same shared
  # lineage via hosts/rpi5/hermes/hermes.nix.
  home.file = sharedSkillFiles // claudeCommandFiles // {
    # Writable settings.json — symlinked to the repo checkout so /voice etc.
    # can update it at runtime.
    ".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/claude-settings.json";

    # Second Claude config dir (~/.claude-secondary) — tiny-llm-gate's acct2
    # spare login (see hosts/rpi5/claude/claude-oauth-2.nix). Its settings.json was previously
    # unmanaged; point it at the SAME baseline as ~/.claude so it inherits the
    # Aperture gate URL, permissions and hooks — one source of truth. Writable
    # out-of-store symlink; note runtime toggles (/voice, theme, …) are shared
    # with the primary config since both symlink the same file.
    ".claude-secondary/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/claude-settings.json";

    # Keybindings — Enter submits, Shift+Enter inserts a newline. Symlinked to
    # the repo checkout (not the Nix store) so it stays hand-editable.
    # Baseline: home/dotfiles/claude-keybindings.json
    ".claude/keybindings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/claude-keybindings.json";

    # Unified agent notify gate (see home/scripts/claude-notify.sh). Wired
    # under three hook events in claude-settings.json: UserPromptSubmit
    # (`activity`), Notification (`notification`, idle-gated), and
    # PostToolUse/PushNotification (`push`, always through). Shared with the
    # remote-control bridge via the ~/.claude-rc/hooks symlink.
    #
    # The script owns the idle gating only; the payload + POST to the :8088
    # aggregator is the shared seam (shared/notify.nix `agent`), handed over as
    # $AGENT_NOTIFY. This wrapper is the sole entry point, so that variable is
    # always set.
    ".claude/hooks/claude-notify" = {
      source = pkgs.writeShellScript "claude-notify" ''
        export AGENT_NOTIFY=${agentNotify}
        exec ${pkgs.bash}/bin/bash ${./scripts/claude-notify.sh} "$@"
      '';
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

    # PostToolUse hook: mirror writes under
    # ~/.claude/projects/-home-nsimon-nic-os/memory/ into AFFiNE
    # Wiki/Pages/Claude Memory/ via the affine-mcp HTTP bridge.
    # Shipped as a console script of the nicos-scripts package rather than a raw
    # .py: a loose file relies on a `python3` happening to be on the hook's PATH
    # and declares no dependencies. The wrapper pins its own interpreter.
    ".claude/hooks/memory-sync".source =
      "${pkgs.nicos-scripts}/bin/claude-memory-sync";

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
    #
    # NB: the same entry also used to sit ungated in the base set above, and `//`
    # takes the right operand — so on Linux the base definition simply survived
    # and this gate did nothing. Removed there; this is now the only definition.
    "MyDocuments/TRUSK/CLAUDE.md".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/trusk-CLAUDE.md";
  };

}
