{
  config,
  pkgs,
  lib,
  ...
}:
{
  systemd.user.services.openclaw-gateway.Service.EnvironmentFile =
    "/home/nsimon/.secrets/openclaw.env";
  systemd.user.services.openclaw-gateway.Install.WantedBy = [ "default.target" ];

  programs.openclaw = {
    documents = ./openclaw-documents;

    skills =
      let
        skillEntries = builtins.readDir ./openclaw-documents/skills;
        skillDirs = builtins.filter (name: skillEntries.${name} == "directory")
          (builtins.attrNames skillEntries);
      in
      map (name: {
        inherit name;
        mode = "copy";
        source = toString (./openclaw-documents/skills + "/${name}");
      }) skillDirs;

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
          # Explicit heartbeat configuration (replaces OpenClaw's internal default)
          heartbeat = {
            every = "1h";   # Every 1 hour
            activeHours = {
              start = "09:00";
              end = "23:00";
              timezone = "Europe/Paris";
            };
            suppressToolErrorWarnings = true;
          };
        };

        channels.telegram = {
          enabled = true;
          tokenFile = "/home/nsimon/.secrets/telegram-bot-token";
          allowFrom = [ 82389391 ];
          groups."*".requireMention = true;
          timeoutSeconds = 120;
        };

        plugins.entries = {
          "telegram".enabled = true;
        };
      };
    };
  };
}
