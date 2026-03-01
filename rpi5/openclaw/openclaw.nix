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
  systemd.user.services.openclaw-gateway.Service.Environment =
    [ "OPENCLAW_BUNDLED_PLUGINS_DIR=${bundledExtensionsDir}" ];
  systemd.user.services.openclaw-gateway.Service.ExecStartPre = [
    "${pkgs.coreutils}/bin/mkdir -p ${bundledExtensionsDir}"
    "${pkgs.coreutils}/bin/mkdir -p ${customAcpxDir}"
    "${pkgs.bash}/bin/bash -eu -c 'if [ -d \"${bundledExtensionsSource}\" ]; then ${pkgs.rsync}/bin/rsync -a --delete \"${bundledExtensionsSource}/\" \"${bundledExtensionsDir}/\"; fi'"
    "${pkgs.bash}/bin/bash -eu -c 'if [ -d \"${customAcpxSource}\" ]; then ${pkgs.rsync}/bin/rsync -a --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \"${customAcpxSource}/\" \"${customAcpxDir}/\"; fi'"
    "${pkgs.coreutils}/bin/ln -sfn ${bundledNodeModulesSource} ${bundledNodeModulesLink}"
  ];
  systemd.user.services.openclaw-gateway.Install.WantedBy = [ "default.target" ];

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
          };
        };

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
          defaultAgent = "cursor-agent";
          allowedAgents = [ "cursor-agent" "codex" ];
        };

        plugins.load.paths = [ customAcpxDir ];
        plugins.entries.acpx.enabled = true;

        plugins.entries."voice-call" = {
          enabled = true;
          provider = "mock";
          inboundPolicy = "disabled";
        };
      };
    };
  };
}
