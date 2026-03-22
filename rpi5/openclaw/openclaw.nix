{
  config,
  pkgs,
  lib,
  nClawSkillsSource,
  openclawSource,
  telegramChatId,
  ...
}:
let
  bundledRuntimeDir = "/home/nsimon/.openclaw/bundled-runtime";
  bundledExtensionsDir = "${bundledRuntimeDir}/extensions";
  bundledNodeModulesLink = "${bundledRuntimeDir}/node_modules";
  bundledExtensionsSource = "${pkgs.openclaw-gateway}/lib/openclaw/extensions";
  bundledNodeModulesSource = "${pkgs.openclaw-gateway}/lib/openclaw/node_modules";
  # Nix store files are hard-linked (nlink>1); openclaw's openBoundaryFileSync rejects hardlinked
  # files by default. Copy control-ui assets to writable dir (nlink=1) so the gateway can serve them.
  controlUiSource = "${pkgs.openclaw-gateway}/lib/openclaw/dist/control-ui";
  controlUiRoot = "${bundledRuntimeDir}/control-ui";
  customExtensionsDir = "/home/nsimon/.openclaw/custom-extensions";
  customAcpxDir = "${customExtensionsDir}/acpx";
  customAcpxSource = "${openclawSource}/extensions/acpx";
in
{
  systemd.user.services.openclaw-gateway.Service.EnvironmentFile =
    "/run/agenix/openclaw-env";
  systemd.user.services.openclaw-gateway.Service.Environment = [
    "OPENCLAW_BUNDLED_PLUGINS_DIR=${bundledExtensionsDir}"
    "OPENCLAW_NO_RESPAWN=1"
    "NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache"
  ];
  systemd.user.services.openclaw-gateway.Service.ExecStartPre = [
    "${pkgs.coreutils}/bin/mkdir -p /var/tmp/openclaw-compile-cache"
    "${pkgs.coreutils}/bin/mkdir -p ${bundledExtensionsDir}"
    "${pkgs.coreutils}/bin/mkdir -p ${controlUiRoot}"
    "${pkgs.coreutils}/bin/mkdir -p ${customAcpxDir}"
    "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/chmod -R u+w \"${bundledExtensionsDir}\" 2>/dev/null || true'"
    "${pkgs.coreutils}/bin/rm -rf ${bundledExtensionsDir}/acpx"
    "${pkgs.bash}/bin/bash -eu -c 'if [ -d \"${bundledExtensionsSource}\" ]; then ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r --exclude \"acpx/\" \"${bundledExtensionsSource}/\" \"${bundledExtensionsDir}/\"; fi'"
    "${pkgs.bash}/bin/bash -eu -c 'if [ -d \"${customAcpxSource}\" ]; then ${pkgs.rsync}/bin/rsync -a --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \"${customAcpxSource}/\" \"${customAcpxDir}/\"; fi'"
    "${pkgs.coreutils}/bin/ln -sfn ${bundledNodeModulesSource} ${bundledNodeModulesLink}"
    # Copy control-ui to writable dir; nix store hard-links (nlink>1) are rejected by openBoundaryFileSync
    "${pkgs.bash}/bin/bash -eu -c 'if [ -d \"${controlUiSource}\" ]; then ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Fu+rw \"${controlUiSource}/\" \"${controlUiRoot}/\"; fi'"
  ];
  systemd.user.services.openclaw-gateway.Install.WantedBy = [ "default.target" ];
  home.sessionVariables = {
    OPENCLAW_BUNDLED_PLUGINS_DIR = bundledExtensionsDir;
    OPENCLAW_NO_RESPAWN = "1";
    NODE_COMPILE_CACHE = "/var/tmp/openclaw-compile-cache";
  };
  programs.zsh.sessionVariables = {
    OPENCLAW_BUNDLED_PLUGINS_DIR = bundledExtensionsDir;
    OPENCLAW_NO_RESPAWN = "1";
    NODE_COMPILE_CACHE = "/var/tmp/openclaw-compile-cache";
  };
  programs.zsh.envExtra = ''
    export OPENCLAW_BUNDLED_PLUGINS_DIR="${bundledExtensionsDir}"
    export OPENCLAW_NO_RESPAWN=1
    export NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
    [ -r /run/agenix/openclaw-env ] && source /run/agenix/openclaw-env
    [ -n "$ANTHROPIC_API_KEY" ] && export CLAUDE_CODE_OAUTH_TOKEN="$ANTHROPIC_API_KEY"
  '';
  home.activation.copyOpenClawBundledPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.coreutils}/bin/mkdir -p /var/tmp/openclaw-compile-cache
    ${pkgs.coreutils}/bin/mkdir -p ${bundledExtensionsDir}
    ${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/chmod -R u+w "${bundledExtensionsDir}" 2>/dev/null || true'
    ${pkgs.coreutils}/bin/rm -rf ${bundledExtensionsDir}/acpx || true
    if [ -d "${bundledExtensionsSource}" ]; then
      ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r --exclude "acpx/" "${bundledExtensionsSource}/" "${bundledExtensionsDir}/"
    fi
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

        commands = {
          native = true;
          nativeSkills = true;
        };

        agents.defaults = {
          skipBootstrap = true;
          model = {
            primary = "openai-codex/gpt-5.3-codex";
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
            "openai-codex/gpt-5.3-codex" = {
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
        };
      };
    };
  };
}
