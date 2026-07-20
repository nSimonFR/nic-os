{
  config,
  pkgs,
  inputs,
  telegramChatId,
  unstablePkgs,
  apertureUrl,
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
  # Merge picoclaw-local skills (./skills) with the shared cross-agent
  # skills under shared/skills/ (wired into claude/codex/pi by
  # home/claude.nix). Local entries win on name collisions, so an
  # override at rpi5/picoclaw/skills/<name>/ trumps the shared version.
  skillsSource = pkgs.runCommand "picoclaw-skills" { } ''
    mkdir -p $out
    cp -r ${../../shared/skills}/. $out/
    cp -rf ${./skills}/. $out/
  '';
  documentsSource = ./documents;

  # LiteLLM runs on localhost:4001 (see rpi5/litellm.nix). It exposes an
  # OpenAI-compatible API and handles model routing + fallback. PicoClaw sees
  # a single "primary" model here; LiteLLM decides where the request actually goes.
  litellmBase = "${apertureUrl}/v1";

  picoclawConfig = {
    agents.defaults = {
      workspace = workspaceDir;
      # Skills routinely shell out to tools installed system-wide (firefly CLI,
      # gh, curl, custom scripts in /home/nsimon) and read paths outside
      # ~/.picoclaw/workspace/. Sandboxing the agent to the workspace would
      # break most skills. Trust model here is the single-chat-ID allowlist
      # on the Telegram channel, not workspace isolation.
      restrict_to_workspace = false;
      model_name = "terra";
      max_tokens = 8192;
      context_window = 131072;
      temperature = 0.7;
      max_tool_iterations = 100;
      summarize_message_threshold = 20;
      summarize_token_percent = 75;
    };

    # Flat model list keyed by `model_name`. Routing and fallback are done by
    # tiny-llm-gate, not PicoClaw. The default is `terra` (GPT-5.6 Terra, the
    # balanced coding tier); `sol` (flagship) and `luna` (high-volume) are
    # selectable per-chat. Each 5.6 tier falls back to Ollama gemma4:e4b at the
    # gate when codex/OAuth is down, so the assistant keeps answering (with
    # Aperture observability on the local hop). gemma-*/qwen remain as explicit
    # local-model picks.
    model_list = [
      {
        model_name = "sol";
        model = "openai/gpt-5.6"; # Sol — bare gpt-5.6 is OpenAI's flagship alias
        api_base = litellmBase;
        api_key = "unused";
      }
      {
        model_name = "terra";
        model = "openai/gpt-5.6-terra";
        api_base = litellmBase;
        api_key = "unused";
      }
      {
        model_name = "luna";
        model = "openai/gpt-5.6-luna";
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
        model = "openai/qwen3.6:35b-a3b";
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
      # Senders (not chats): adding a user id also grants them DM access.
      allow_from = [
        (toString telegramChatId) # nSimon
        "8627259779" # Alfie
      ];
      use_markdown_v2 = false;
      streaming.enabled = true;
      # Respond to every message in group chats, not only when @mentioned.
      # `mention_only = false` is picoclaw's permissive default; the only group
      # the bot is in is "nSimon, ServaTilis and Alfie", so this makes it reply
      # to all of Alfie's messages there. (`require_mention_in_groups` is
      # silently ignored by picoclaw's schema — the real key is
      # `group_trigger.mention_only`.) Setting is global per channel: picoclaw
      # has no per-chat granularity.
      group_trigger.mention_only = false;
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

      # Only AFFiNE for now — URL sourced from home/mcp.nix so picoclaw,
      # Claude Code and Cursor stay aligned on the bridge endpoint. Other
      # personal MCPs (firecrawl, Miro, GitHub, Linear) are intentionally
      # left out until their failure modes are resolved (docker dep, OAuth,
      # SSE protocol mismatch).
      #
      # discovery.enabled = true puts MCP tools behind a search_tools call
      # rather than dumping every tool description into the system prompt
      # — keeps the agent's upfront context small as we bring back the
      # high-tool-count servers (Miro alone exposes 97 tools).
      mcp = {
        enabled = true;
        discovery = {
          enabled = true;
          use_bm25 = true;
          max_search_results = 20;
        };
        servers = {
          # picoclaw's MCP client (pkg/mcp/manager.go) speaks ONLY Streamable
          # HTTP (go-sdk StreamableClientTransport) for BOTH type "sse" and
          # "http": it POSTs `initialize` straight to the URL and never performs
          # the legacy-SSE GET handshake. The shared home/mcp.nix bridge URL
          # ends in /sse (legacy SSE, GET-only) → picoclaw hit 405 "Method Not
          # Allowed" and loaded zero MCP tools. tiny-llm-gate only bridges
          # SSE-to-client (no Streamable-HTTP client endpoint), so point picoclaw
          # straight at the local affine-mcp backend's Streamable HTTP endpoint
          # (loopback, no gate/tailnet hop). The bearer header is injected into
          # the runtime config.json by setupScript so the token (a 0444 agenix
          # secret) never enters the Nix store.
          affine = {
            enabled = true;
            type = "http";
            url = "http://127.0.0.1:7021/mcp";
          };
        };
      };
    };

    gateway = {
      host = "127.0.0.1";
      # Reuse OpenClaw's port so Tailscale Serve (:443 → :18789) keeps working
      # without downstream changes.
      port = 18789;
      log_level = "info";
    };

    # RTK (Rust Token Killer) transparent rewriting via a `before_tool` process
    # hook (JSON-RPC over stdio — pkg/agent/hook_process.go). The hook rewrites
    # the `exec` tool's `command` to its `rtk`-prefixed equivalent so picoclaw's
    # LLM sees 60–90% fewer tokens of command output. `intercept` takes hook
    # STAGE names (not tool names); `RTK_BIN` is an absolute store path so the
    # hook finds rtk regardless of PATH. Fails open (see rtk-hook.py).
    hooks = {
      enabled = true;
      processes.rtk = {
        enabled = true;
        transport = "stdio";
        command = [ "${pkgs.python3}/bin/python3" "${./rtk-hook.py}" ];
        intercept = [ "before_tool" ];
        env.RTK_BIN = "${pkgs.rtk}/bin/rtk";
      };
    };
  };

  configFile = pkgs.writeText "picoclaw-config.json" (builtins.toJSON picoclawConfig);

  # Setup script (ExecStartPre): materialise config.json + skills/documents into
  # the workspace. Runs on every restart, keeping the workspace in sync with
  # the Nix store without home-manager file-conflict headaches.
  setupScript = pkgs.writeShellScript "picoclaw-setup" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p ${configDir} ${workspaceDir} ${workspaceDir}/skills
    ${pkgs.coreutils}/bin/install -m 0600 ${configFile} ${configDir}/config.json

    # Inject the AFFiNE MCP bearer into the runtime config.json. The token is a
    # secret (0444 agenix file) so it must NOT be baked into ${configFile}
    # (which lands world-readable in the Nix store). picoclaw does no env
    # expansion on the MCP `headers` map, so patch the literal value in here at
    # start time. Mode 0600 above (picoclaw also rewrites it 0600 on migration).
    affine_tok="$(${pkgs.coreutils}/bin/cat /run/agenix/affine-mcp-http-token)"
    ${pkgs.jq}/bin/jq \
      --arg auth "Bearer $affine_tok" \
      '.tools.mcp.servers.affine.headers.Authorization = $auth' \
      ${configDir}/config.json > ${configDir}/config.json.tmp
    ${pkgs.coreutils}/bin/mv ${configDir}/config.json.tmp ${configDir}/config.json

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
    # Default chat for skills that talk to Telegram directly (e.g. immich-memories
    # posts an album via the Bot API — picoclaw can't build media groups). The
    # numeric chat id isn't surfaced to the model, so wire it from the flake.
    TELEGRAM_CHAT_ID="${toString telegramChatId}"
    set +a
    export HOME="/home/nsimon"
    # systemd --user starts services with a minimal PATH (just systemd/bin).
    # Picoclaw's exec tool invokes `sh -c <command>` and inherits our env, so
    # without a real PATH every shell-out fails with "sh: not found".
    # Match what an interactive nsimon shell sees: home-manager's own bin
    # (gog/goplaces/summarize live *only* there, not in ~/.nix-profile/bin),
    # user profile, system profile, wrappers, and nix-profile.
    # ${pkgs.rtk}/bin is prepended explicitly so the rtk-prefixed commands the
    # before_tool hook rewrites to (e.g. `rtk git status`) resolve even before
    # home-manager activation has linked rtk into home-path/bin.
    export PATH="${pkgs.rtk}/bin:$HOME/.local/state/nix/profiles/home-manager/home-path/bin:/etc/profiles/per-user/nsimon/bin:/run/current-system/sw/bin:/run/wrappers/bin:$HOME/.nix-profile/bin:$PATH"
    exec ${picoclaw}/bin/picoclaw gateway
  '';
in
{
  home.packages = [ picoclaw ];

  # vdirsyncer + khal configs for the `caldav-calendar` skill. Colocated here
  # (not in home.nix) because the skill is picoclaw's consumer. Both tools come
  # from home.packages in rpi5/home.nix; the configs live in $HOME/.config/.
  #
  # vdirsyncer reads the Nextcloud password lazily via `password.fetch` — the
  # `cat` command runs at sync time as the nsimon user, which can read the
  # 0400-mode agenix file. No env var, no NEXTCLOUD_PASSWORD plumbing in the
  # exec wrapper.
  home.file.".config/vdirsyncer/config".text = ''
    [general]
    status_path = "~/.local/share/vdirsyncer/status/"

    [pair nextcloud]
    a = "nc_remote"
    b = "nc_local"
    collections = ["from a"]
    conflict_resolution = "a wins"
    metadata = ["color", "displayname"]

    [storage nc_remote]
    type = "caldav"
    url = "https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/"
    username = "nsimon"
    password.fetch = ["command", "cat", "/run/agenix/nextcloud-homepage-password"]

    [storage nc_local]
    type = "filesystem"
    path = "~/.local/share/vdirsyncer/calendars/"
    fileext = ".ics"
  '';

  home.file.".config/khal/config".text = ''
    [calendars]
    [[nextcloud]]
    path = ~/.local/share/vdirsyncer/calendars/*
    type = discover

    [locale]
    timeformat = %H:%M
    dateformat = %Y-%m-%d
    longdateformat = %Y-%m-%d %a
    datetimeformat = %Y-%m-%d %H:%M
    longdatetimeformat = %Y-%m-%d %a %H:%M

    [default]
    highlight_event_days = True
  '';

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
