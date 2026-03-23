{
  config,
  pkgs,
  lib,
  nClawSkillsSource,
  openclawSource,
  telegramChatId,
  tailnetFqdn,
  voiceWebhookPort,
  ...
}:
let
  bundledRuntimeDir = "/home/nsimon/.openclaw/bundled-runtime";
  bundledExtensionsDir = "${bundledRuntimeDir}/extensions";
  bundledNodeModulesLink = "${bundledRuntimeDir}/node_modules";
  bundledExtensionsSource = "${pkgs.openclaw-gateway}/lib/openclaw/extensions";
  bundledNodeModulesSource = "${pkgs.openclaw-gateway}/lib/openclaw/node_modules";
  # The bundled core skills live inside the openclaw npm package under the pnpm store.
  # resolveBundledSkillsDir() auto-detection fails in our nix layout; use the env var override.
  # We create a stable symlink so the path survives pkg updates without changing the env var.
  bundledSkillsLink = "${bundledRuntimeDir}/skills";
  # Nix store files are hard-linked (nlink>1); openclaw's openBoundaryFileSync rejects hardlinked
  # files by default. Copy control-ui assets to writable dir (nlink=1) so the gateway can serve them.
  controlUiSource = "${pkgs.openclaw-gateway}/lib/openclaw/dist/control-ui";
  controlUiRoot = "${bundledRuntimeDir}/control-ui";
  customExtensionsDir = "/home/nsimon/.openclaw/custom-extensions";
  customAcpxDir = "${customExtensionsDir}/acpx";
  customAcpxSource = "${openclawSource}/extensions/acpx";
  # Single setup script shared by both ExecStartPre (service start) and the activation hook (rebuild).
  # Nix store files are hard-linked (nlink>1); openclaw's openBoundaryFileSync rejects them, so
  # extensions and control-ui are rsynced to writable dirs on every start/rebuild.
  setupScript = pkgs.writeShellScript "openclaw-setup" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p /var/tmp/openclaw-compile-cache
    ${pkgs.coreutils}/bin/mkdir -p ${bundledExtensionsDir}
    ${pkgs.coreutils}/bin/mkdir -p ${controlUiRoot}
    ${pkgs.coreutils}/bin/mkdir -p ${customAcpxDir}
    ${pkgs.coreutils}/bin/chmod -R u+w ${bundledExtensionsDir} 2>/dev/null || true
    ${pkgs.coreutils}/bin/rm -rf ${bundledExtensionsDir}/acpx
    if [ -d ${bundledExtensionsSource} ]; then
      ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r --exclude "acpx/" "${bundledExtensionsSource}/" "${bundledExtensionsDir}/"
    fi
    if [ -d ${customAcpxSource} ]; then
      ${pkgs.rsync}/bin/rsync -a --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r "${customAcpxSource}/" "${customAcpxDir}/"
    fi
    ${pkgs.coreutils}/bin/ln -sfn ${bundledNodeModulesSource} ${bundledNodeModulesLink}
    _s=$(${pkgs.coreutils}/bin/ls -d "${bundledNodeModulesSource}/.pnpm/openclaw@"*/node_modules/openclaw/skills 2>/dev/null | ${pkgs.coreutils}/bin/head -1)
    [ -n "$_s" ] && [ -d "$_s" ] && ${pkgs.coreutils}/bin/ln -sfn "$_s" "${bundledSkillsLink}"
    if [ -d ${controlUiSource} ]; then
      ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Fu+rw "${controlUiSource}/" "${controlUiRoot}/"
    fi
  '';
in
{
  # Always overwrite openclaw.json on deploy rather than backing it up.
  # The openclaw-gateway service rewrites this file at runtime, causing
  # home-manager conflicts on every nixos-rebuild if force = false.
  home.file.".openclaw/openclaw.json".force = true;

  systemd.user.services.openclaw-gateway.Service.EnvironmentFile =
    "/run/agenix/openclaw-env";
  systemd.user.services.openclaw-gateway.Service.Environment = [
    "OPENCLAW_BUNDLED_PLUGINS_DIR=${bundledExtensionsDir}"
    "OPENCLAW_BUNDLED_SKILLS_DIR=${bundledSkillsLink}"
    "OPENCLAW_NO_RESPAWN=1"
    "NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache"
  ];
  systemd.user.services.openclaw-gateway.Service.ExecStartPre = [ "${setupScript}" ];
  systemd.user.services.openclaw-gateway.Install.WantedBy = [ "default.target" ];
  programs.zsh.envExtra = ''
    export OPENCLAW_BUNDLED_PLUGINS_DIR="${bundledExtensionsDir}"
    export OPENCLAW_BUNDLED_SKILLS_DIR="${bundledSkillsLink}"
    export OPENCLAW_NO_RESPAWN=1
    export NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
    [ -r /run/agenix/openclaw-env ] && source /run/agenix/openclaw-env
    [ -n "$ANTHROPIC_API_KEY" ] && export CLAUDE_CODE_OAUTH_TOKEN="$ANTHROPIC_API_KEY"
  '';
  # Restore OpenAI Codex OAuth auth profile on fresh install (only if missing).
  # openclaw manages token rotation itself; we never overwrite an existing file.
  home.activation.restoreOpenClawCodexAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _authDir="/home/nsimon/.openclaw/agents/main/agent"
    _authFile="$_authDir/auth-profiles.json"
    _secretFile="/run/agenix/openclaw-codex-auth"
    if [ ! -f "$_authFile" ] && [ -r "$_secretFile" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$_authDir"
      ${pkgs.coreutils}/bin/install -m 600 "$_secretFile" "$_authFile"
    fi
  '';

  # Openclaw 2026.3.14+ rejects skill SKILL.md paths whose realpath escapes the workspace root.
  # Home-manager places these as symlinks → /nix/store/..., which fail the security check.
  # Fix: replace each symlink with a real copy so realpath stays inside the workspace.
  home.activation.fixOpenClawSkillSymlinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _skillsDir="/home/nsimon/.openclaw/workspace/skills"
    if [ -d "$_skillsDir" ]; then
      while IFS= read -r _link; do
        _target=$(${pkgs.coreutils}/bin/readlink -f "$_link")
        if [ -f "$_target" ]; then
          ${pkgs.coreutils}/bin/cp "$_target" "$_link.tmp" && ${pkgs.coreutils}/bin/mv "$_link.tmp" "$_link"
        fi
      done < <(${pkgs.findutils}/bin/find "$_skillsDir" -name "SKILL.md" -type l)
    fi
  '';

  home.activation.copyOpenClawBundledPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${setupScript}
  '';

  programs.openclaw = {
    documents = ./documents;
    excludeTools = [ "pnpm" ];

    customPlugins = [
      {
        source = nClawSkillsSource;
      }
      # nix-steipete-tools tool flakes hardcode nixpkgs@16c7794 with a narHash incompatible
      # with Nix 2.31.2 (assertion crash in flake.cc:37). Local wrappers fix this by following
      # our nixpkgs so the wrong inner narHash is never evaluated.
      {
        source = "path:/home/nsimon/nic-os/rpi5/openclaw/plugins/summarize";
      }
      {
        source = "path:/home/nsimon/nic-os/rpi5/openclaw/plugins/gogcli";
      }
      {
        source = "path:/home/nsimon/nic-os/rpi5/openclaw/plugins/goplaces";
      }
    ];

    bundledPlugins = {
      # Disabled: bundled path uses ?dir= URL format that triggers a Nix 2.31.2 assertion crash
      # (flake.cc:37). Re-added above as customPlugins via local narHash-compatible wrappers.
      summarize.enable = false;
      # peekaboo/sag: macOS-only or unavailable on aarch64-linux — keep disabled.
      peekaboo.enable = false;
      sag.enable = false;
      gogcli.enable = false;
      goplaces.enable = false;
    };

    instances.default = {
      enable = true;

      config = {
        gateway.mode = "local";

        # Gateway bound to loopback; access can be direct on tailnet or via Tailscale Serve HTTPS (WSS).
        gateway.bind = "loopback";
        gateway.auth.mode = "token";
        gateway.auth.token = "\${OPENCLAW_GATEWAY_TOKEN}";

        # Web control UI served through nginx portal at /openclaw/ (basePath tells the gateway its prefix)
        gateway.controlUi.enabled = true;
        gateway.controlUi.basePath = "/openclaw";
        gateway.controlUi.root = controlUiRoot;

        gateway.port = 18789;
        gateway.tailscale.mode = "off";
        gateway.tailscale.resetOnExit = false;

        commands = {
          native = true;
          nativeSkills = true;
          restart = true;
          ownerDisplay = "raw";
        };

        session.dmScope = "per-channel-peer";

        # "coding" profile includes exec + process (messaging profile does not).
        # tools.allow was removed: an explicit allowlist acts as a filter that would
        # block all messaging tools while exec/process weren't in the messaging profile,
        # resulting in zero registered function-calling tools.
        tools.profile = "coding";

        # openai-codex OAuth profile (populated by openclaw onboarding wizard).
        auth.profiles."openai-codex:default" = {
          provider = "openai-codex";
          mode = "oauth";
        };

        agents.defaults = {
          skipBootstrap = true;
          model = {
            primary = "openai-codex/gpt-5.4";
            fallbacks = [ "anthropic/claude-haiku-4-5" ];
          };
          models = {
            "anthropic/claude-sonnet-4-6" = {
              alias = "sonnet";
            };
            "anthropic/claude-opus-4-6" = {
              alias = "opus";
            };
            # "google/gemini-2.5-flash-lite" = {
            #   alias = "flash";
            # };
            "anthropic/claude-haiku-4-5" = {
              alias = "haiku";
            };
            "openai-codex/gpt-5.4" = {
              alias = "codex";
            };
          };
          heartbeat = {
            every = "1h";
            activeHours = {
              start = "09:00";
              end = "23:00";
              timezone = "Europe/Paris";
            };
            # Explicit Telegram delivery target for visible heartbeat reports.
            target = "telegram";
            to = builtins.toString telegramChatId;
            accountId = "default";
            directPolicy = "allow";
          };
        };

        # Enable classic subagent runtime alongside ACP runtime.
        agents.list = [
          {
            id = "main";
            default = true;
          }
        ];

        channels.telegram = {
          enabled = true;
          tokenFile = config.age.secrets.telegram-bot-token.path;
          allowFrom = [ telegramChatId ];
          groups."*".requireMention = true;
          timeoutSeconds = 120;
          streaming = "partial";
        };

        tools.sessions.visibility = "all";
        tools.agentToAgent.enabled = true;

        acp = {
          dispatch.enabled = true;
          defaultAgent = "cursor-agent";
          allowedAgents = [
            "cursor-agent"
            "codex"
            "claude"
          ];
        };

        plugins.load.paths = [ customAcpxDir ];
        plugins.entries.acpx.enabled = true;

        plugins.entries."voice-call" = {
          enabled = true;
          config = {
            provider = "twilio";
            fromNumber = "+33159580386";

            twilio = {
              accountSid = "\${TWILIO_ACCOUNT_SID}";
              authToken = "\${TWILIO_AUTH_TOKEN}";
            };

            serve = {
              port = voiceWebhookPort;
              path = "/voice/webhook";
            };

            # Explicit public webhook URL for Twilio signature validation
            # when OpenClaw is behind an external tunnel/proxy.
            publicUrl = "https://${tailnetFqdn}:${toString voiceWebhookPort}/voice/webhook";

            outbound.defaultMode = "notify";

            # Inbound calls (secure allowlist mode)
            inboundPolicy = "allowlist";
            allowFrom = [ "+33612356362" ];
            inboundGreeting = "Hello, this is OpenClaw. How can I help you?";
          };
        };
      };
    };
  };
}
