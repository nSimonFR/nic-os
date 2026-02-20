{
  config,
  pkgs,
  lib,
  ...
}:
{
  systemd.user.services.openclaw-gateway.Service.EnvironmentFile =
    "/home/nsimon/.secrets/openclaw.env";

  programs.openclaw = {
    documents = ./openclaw-documents;

    skills = map (name: {
      inherit name;
      mode = "copy";
      source = toString (./openclaw-documents/skills + "/${name}");
    }) (builtins.attrNames (builtins.readDir ./openclaw-documents/skills));

    bundledPlugins = {
      summarize.enable = true;
      peekaboo.enable = false;
      sag.enable = false;
    };

    instances.default = {
      enable = true;

      config = {
        gateway.mode = "local";
        
        # Direct Tailnet: gateway listens on Tailscale IP, reachable as ws://rpi5:18789 (MagicDNS)
        # No Serve needed; same tailnet = direct access. Token from openclaw.env.
        gateway.bind = "tailnet";
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
