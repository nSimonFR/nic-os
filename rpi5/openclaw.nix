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
    documents = ./documents;

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

        agents.defaults = {
          skipBootstrap = true;
          model = {
            primary = "anthropic/claude-haiku-3.5";
            fallbacks = [ ];
          };
          models = {
            "anthropic/claude-sonnet-4-5" = {
              alias = "sonnet";
            };
            "anthropic/claude-opus-4-6" = {
              alias = "opus";
            };
            "google/gemini-2.0-flash" = {
              alias = "flash";
            };
            "anthropic/claude-haiku-3.5" = {
              alias = "haiku";
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
      };
    };
  };
}
