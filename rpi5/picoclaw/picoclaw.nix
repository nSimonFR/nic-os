{
  pkgs,
  inputs,
  telegramChatId,
  unstablePkgs,
  ...
}:
# PicoClaw home-manager module.
#
# Replaces the OpenClaw gateway with Sipeed's Go-based AI agent. Single Go binary,
# single systemd user unit, JSON config. Expects an agenix secret `picoclaw-env`
# with TELEGRAM_BOT_TOKEN, TAVILY_API_KEY, and other service credentials.
#
# Model resilience: PicoClaw points at the local LiteLLM gateway (:4001). Fallback
# from OpenAI Codex → Ollama (gemma4) is configured in litellm.nix, so PicoClaw
# only ever sees one OpenAI-compatible endpoint.
#
# Key simplifications vs OpenClaw:
#   - No plugin flakes, no setup script, no bundled runtime rsync dance
#   - Skills are just directories under workspace/skills with SKILL.md files
#   - No voice/Twilio (deferred — revisit later if needed)
#   - No ACP dispatch, no heartbeat (covered by Prometheus/Beszel alerting)
#   - No web UI (Telegram-only access)
#
# Runtime layout (per PicoClaw conventions):
#   ~/.picoclaw/config.json         — generated below, overwritten on rebuild
#   ~/.picoclaw/workspace/          — skills, documents, memory (rsync'd from Nix)
#   ~/.picoclaw/workspace/skills/   — SKILL.md-formatted skills (migrated from OpenClaw)
let
  # Use unstablePkgs.buildGoModule (Go 1.26.x) — nixpkgs 25.11 ships Go 1.25.8
  # which is too old for picoclaw's go.mod (requires ≥1.25.9). `unstablePkgs`
  # is passed in via extraSpecialArgs (standalone HM) or pkgs.unstablePkgs
  # overlay (NixOS HM); destructuring the arg covers both with one source.
  picoclaw = pkgs.callPackage ./package.nix {
    inherit (unstablePkgs) buildGoModule;
    picoclaw-src = inputs.picoclaw-src;
  };

  configDir = "/home/nsimon/.picoclaw";
  workspaceDir = "${configDir}/workspace";
  skillsSource = ./skills;
  documentsSource = ./documents;

  # LiteLLM runs on localhost:4001 (see rpi5/litellm.nix). It exposes an
  # OpenAI-compatible API and handles model routing + fallback. PicoClaw sees
  # a single "primary" model here; LiteLLM decides where the request actually goes.
  litellmBase = "http://127.0.0.1:4001/v1";

  picoclawConfig = {
    agents.defaults = {
      workspace = workspaceDir;
      # Skills routinely shell out to tools installed system-wide (firefly CLI,
      # gh, curl, custom scripts in /home/nsimon) and read paths outside
      # ~/.picoclaw/workspace/. Sandboxing the agent to the workspace would
      # break most skills. Trust model here is the single-chat-ID allowlist
      # on the Telegram channel, not workspace isolation.
      restrict_to_workspace = false;
      model_name = "primary";
      max_tokens = 8192;
      context_window = 131072;
      temperature = 0.7;
      max_tool_iterations = 20;
      summarize_message_threshold = 20;
      summarize_token_percent = 75;
    };

    # Flat model list keyed by `model_name`. Routing and fallback are done by
    # LiteLLM, not PicoClaw. `primary` goes to LiteLLM's `openai/gpt-5.4` route
    # (which falls back to Ollama via litellm_settings.fallbacks — see litellm.nix).
    # Additional named entries expose specific Ollama models for manual override.
    model_list = [
      {
        model_name = "primary";
        model = "openai/gpt-5.4";
        api_base = litellmBase;
        api_key = "unused";
      }
      {
        model_name = "gemma-medium";
        model = "openai/gemma4:e4b";
        api_base = litellmBase;
        api_key = "unused";
      }
      {
        model_name = "gemma-large";
        model = "openai/gemma4:26b";
        api_base = litellmBase;
        api_key = "unused";
      }
      {
        model_name = "qwen";
        model = "openai/qwen3.5:35b-a3b";
        api_base = litellmBase;
        api_key = "unused";
      }
    ];

    channels.telegram = {
      enabled = true;
      # Token is injected via PICOCLAW_CHANNELS_TELEGRAM_TOKEN env var — picoclaw's
      # struct tags support env overlays natively, so we keep secrets out of
      # config.json entirely (which would otherwise get rewritten by the config
      # migrator on every boot).
      # `allow_from` accepts stringified IDs; numeric-only ID avoids the
      # username/ID mismatch bug reported in sipeed/picoclaw#62/#310.
      allow_from = [ (toString telegramChatId) ];
      use_markdown_v2 = false;
      streaming.enabled = true;
      # Require @mention in groups (OpenClaw parity)
      require_mention_in_groups = true;
    };

    tools = {
      # Core: filesystem, exec, skills, cron — the minimum to replicate
      # OpenClaw's "coding" profile behaviour.
      #
      # allow_remote = true opts out of GHSA-pv8c-p6jf-3fpp's default block on
      # exec from non-internal channels (cli/system/subagent). We rely on
      # Telegram for skill execution, and channels.telegram.allow_from already
      # restricts incoming messages to a single chat ID — so the GHSA threat
      # model (untrusted webhook senders) doesn't apply here.
      exec = {
        enabled = true;
        allow_remote = true;
      };
      skills.enabled = true;

      # Scheduled agent turns (e.g. daily digest at 08:30). Jobs persist in
      # ~/.picoclaw/workspace/cron/jobs.json — the setup rsyncs don't touch
      # that path so jobs survive restarts.
      # allow_command = true lets cron jobs invoke shell commands directly
      # in addition to "send a message to the agent" jobs; GHSA still
      # restricts *scheduling* a command job to internal channels only.
      cron = {
        enabled = true;
        allow_command = true;
      };

      web = {
        enabled = true;
        prefer_native = true;
        duckduckgo.enabled = true;
        # API keys come from PICOCLAW_TOOLS_WEB_TAVILY_API_KEYS (SecureStrings) —
        # see channels.telegram.token for the rationale.
        tavily.enabled = true;
      };

      # MCP servers can be added here to replace specific OpenClaw skills
      # (e.g. GitHub MCP for the `github` skill). Keep disabled until needed.
      mcp = {
        enabled = false;
        servers = { };
      };
    };

    gateway = {
      host = "127.0.0.1";
      # Reuse OpenClaw's port so Tailscale Serve (:443 → :18789) keeps working
      # without downstream changes.
      port = 18789;
      log_level = "info";
    };
  };

  configFile = pkgs.writeText "picoclaw-config.json" (builtins.toJSON picoclawConfig);

  # Setup script (ExecStartPre): materialise config.json + skills/documents into
  # the workspace. Runs on every restart, keeping the workspace in sync with
  # the Nix store without home-manager file-conflict headaches.
  setupScript = pkgs.writeShellScript "picoclaw-setup" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p ${configDir} ${workspaceDir} ${workspaceDir}/skills
    ${pkgs.coreutils}/bin/install -m 0644 ${configFile} ${configDir}/config.json

    # Skills: copy (not symlink) so realpath stays inside the workspace.
    ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \
      "${skillsSource}/" "${workspaceDir}/skills/"

    # Documents: IDENTITY.md, SOUL.md, USER.md, etc. at workspace root.
    ${pkgs.rsync}/bin/rsync -aL --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \
      "${documentsSource}/" "${workspaceDir}/"
  '';

  # ExecStart wrapper: sources picoclaw-env (KEY=VAL agenix file, holding skill
  # credentials consumed by the `exec` tool: HA_TOKEN, FIREFLY_TOKEN, …) and
  # maps the separate single-value secrets (telegram-bot-token, tavily-api-key)
  # onto the PICOCLAW_* env names that picoclaw's config struct tags recognise.
  # Using env vars rather than JSON placeholders means config.json never holds
  # secrets and survives picoclaw's schema migrations unchanged.
  execWrapper = pkgs.writeShellScript "picoclaw-exec" ''
    set -a
    . /run/agenix/picoclaw-env
    PICOCLAW_CHANNELS_TELEGRAM_TOKEN="$(${pkgs.coreutils}/bin/cat /run/agenix/telegram-bot-token)"
    PICOCLAW_TOOLS_WEB_TAVILY_API_KEYS="''${TAVILY_API_KEY:-}"
    set +a
    export HOME="/home/nsimon"
    # systemd --user starts services with a minimal PATH (just systemd/bin).
    # Picoclaw's exec tool invokes `sh -c <command>` and inherits our env, so
    # without a real PATH every shell-out fails with "sh: not found".
    # Match what an interactive nsimon shell sees: home-manager's own bin
    # (gog/goplaces/summarize live *only* there, not in ~/.nix-profile/bin),
    # user profile, system profile, wrappers, and nix-profile.
    export PATH="$HOME/.local/state/nix/profiles/home-manager/home-path/bin:/etc/profiles/per-user/nsimon/bin:/run/current-system/sw/bin:/run/wrappers/bin:$HOME/.nix-profile/bin:$PATH"
    exec ${picoclaw}/bin/picoclaw gateway
  '';
in
{
  home.packages = [ picoclaw ];

  systemd.user.services.picoclaw = {
    Unit = {
      Description = "PicoClaw AI agent gateway";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStartPre = "${setupScript}";
      ExecStart = "${execWrapper}";
      Restart = "on-failure";
      RestartSec = 5;
      # Memory target: PicoClaw claims <20MB; 256M is generous headroom for
      # skill execution without being lax.
      MemoryMax = "256M";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
