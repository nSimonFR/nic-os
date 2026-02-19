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

    bundledPlugins = {
      summarize.enable = true;
      peekaboo.enable = false;
      oracle.enable = false;
      sag.enable = false;
    };

    instances.default = {
      enable = true;

      config = {
        gateway.mode = "local";

        commands = {
          native = true;
          nativeSkills = true;
        };

        agents.defaults = {
          skipBootstrap = true;
          model = {
            primary = "anthropic/claude-haiku-4-5";
            fallbacks = [ "openai-codex/gpt-5.3-codex" ];
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

        # Enable OpenAI Codex (ChatGPT) OAuth so fallback model works
        plugins.entries."openai-codex-auth" = {
          enabled = true;
        };
      };
    };
  };
}
