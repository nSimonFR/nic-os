{
  config,
  pkgs,
  lib,
  nClawSkillsSource,
  openclawSource,
  ...
}:
let
  bundledRuntimeDir = "/home/nsimon/.openclaw/bundled-runtime";
  bundledExtensionsDir = "${bundledRuntimeDir}/extensions";
  bundledNodeModulesLink = "${bundledRuntimeDir}/node_modules";
  bundledExtensionsSource = "${pkgs.openclaw-gateway}/lib/openclaw/extensions";
  bundledNodeModulesSource = "${pkgs.openclaw-gateway}/lib/openclaw/node_modules";
  customExtensionsDir = "/home/nsimon/.openclaw/custom-extensions";
  customAcpxDir = "${customExtensionsDir}/acpx";
  customAcpxSource = "${openclawSource}/extensions/acpx";
in
{
  systemd.user.services.openclaw-gateway.Service.EnvironmentFile =
    "/home/nsimon/.secrets/openclaw.env";
  systemd.user.services.openclaw-gateway.Service.Environment = [
    "OPENCLAW_BUNDLED_PLUGINS_DIR=${bundledExtensionsDir}"
    "PATH=/run/current-system/sw/bin:/run/wrappers/bin:/nix/var/nix/profiles/default/bin"
  ];
  systemd.user.services.openclaw-gateway.Service.ExecStartPre = [
    "${pkgs.coreutils}/bin/mkdir -p ${bundledExtensionsDir}"
    "${pkgs.coreutils}/bin/mkdir -p ${customAcpxDir}"
    "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/chmod -R u+w \"${bundledExtensionsDir}\" 2>/dev/null || true'"
    "${pkgs.coreutils}/bin/rm -rf ${bundledExtensionsDir}/acpx"
    "${pkgs.bash}/bin/bash -eu -c 'if [ -d \"${bundledExtensionsSource}\" ]; then ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r --exclude \"acpx/\" \"${bundledExtensionsSource}/\" \"${bundledExtensionsDir}/\"; fi'"
    "${pkgs.bash}/bin/bash -eu -c 'if [ -d \"${customAcpxSource}\" ]; then ${pkgs.rsync}/bin/rsync -a --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \"${customAcpxSource}/\" \"${customAcpxDir}/\"; fi'"
    "${pkgs.coreutils}/bin/ln -sfn ${bundledNodeModulesSource} ${bundledNodeModulesLink}"
  ];
  systemd.user.services.openclaw-gateway.Install.WantedBy = [ "default.target" ];
  home.sessionVariables = {
    OPENCLAW_BUNDLED_PLUGINS_DIR = bundledExtensionsDir;
  };
  programs.zsh.sessionVariables = {
    OPENCLAW_BUNDLED_PLUGINS_DIR = bundledExtensionsDir;
  };
  programs.zsh.envExtra = ''
    export OPENCLAW_BUNDLED_PLUGINS_DIR="${bundledExtensionsDir}"
  '';
  home.activation.copyOpenClawBundledPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
    ];


    bundledPlugins = {
      summarize.enable = true;
      peekaboo.enable = false;
      sag.enable = false;
      gogcli.enable = true;
    };

    instances.default = {
      enable = true;

      config = {
        gateway.mode = "local";
        
        # Gateway bound to loopback; access can be direct on tailnet or via Tailscale Serve HTTPS (WSS).
        gateway.bind = "loopback";
        gateway.auth.mode = "token";
        gateway.auth.token = "\${OPENCLAW_GATEWAY_TOKEN}";

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
            to = "82389391";
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
          tokenFile = "/home/nsimon/.secrets/telegram-bot-token";
          allowFrom = [ 82389391 ];
          groups."*".requireMention = true;
          timeoutSeconds = 120;
        };

        tools.sessions.visibility = "all";
        tools.agentToAgent.enabled = true;

        acp = {
          dispatch.enabled = true;
          defaultAgent = "cursor-agent";
          allowedAgents = [ "cursor-agent" "codex" "claude" ];
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
              port = 3334;
              path = "/voice/webhook";
            };

            # Explicit public webhook URL for Twilio signature validation
            # when OpenClaw is behind an external tunnel/proxy.
            publicUrl = "https://rpi5.gate-mintaka.ts.net/voice/webhook";

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
