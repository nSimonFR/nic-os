{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.openclaw = {
    # Workspace documents (linked to ~/.openclaw/workspace)
    documents = ./documents;

    # Bundled plugins (some not available on Linux)
    bundledPlugins = {
      summarize.enable = true;
      peekaboo.enable = false; # Not available on Linux
      oracle.enable = false; # Conflicts with summarize on Linux
      sag.enable = false; # macOS only
    };

    instances.default = {
      enable = true;

      # Instance-level config
      # MiniMax M2.1 - best free model for agentic tasks (77.2% τ²-Bench)
      # Auth: run `openclaw onboard --auth-choice minimax-portal` (free OAuth)
      config = {
        gateway = {
          mode = "local";
          # Auth disabled for local testing - add auth.token for production
        };

        # Skip bootstrap template loading (nix package missing templates)
        agents.defaults.skipBootstrap = true;

        # Agent/model configuration
        agents.defaults = {
          model = {
            primary = "ollama/qwen2.5:14b";
            fallbacks = [ ];
          };
          models = {
            "ollama/qwen2.5:14b" = {
              alias = "local";
            };
          };
        };

        # Telegram channel
        # If Telegram disconnects or stops responding, check:
        # 1. openclaw channels status --probe  (token, DNS, HTTPS to api.telegram.org)
        # 2. Token file: ls -la ~/.secrets/telegram-bot-token (must be readable by gateway process)
        # 3. Node 22+: long-polling is known to abort every 20–30 min (AbortError). Options:
        #    - Run gateway on Node 20, or use webhook mode (webhookUrl + webhookSecret) for stability
        # 4. IPv6: if api.telegram.org resolves to AAAA and host has no IPv6, add A record to /etc/hosts or prefer IPv4
        channels.telegram = {
          enabled = true;
          tokenFile = "/home/nsimon/.secrets/telegram-bot-token";
          allowFrom = [ 82389391 ];
          groups = {
            "*" = {
              requireMention = true;
            };
          };
          # Shorter poll timeout can reduce stall duration when long-poll aborts (Node 22+)
          timeoutSeconds = 120;
        };

        # Custom model providers
        models = {
          mode = "merge";
          providers = {
            # Ollama (local)
            ollama = {
              baseUrl = "http://127.0.0.1:11434/v1";
              apiKey = "ollama-local";
              api = "openai-completions";
              models = [
                {
                  id = "qwen2.5:14b";
                  name = "Qwen 2.5 14B (local)";
                  reasoning = false;
                  input = [ "text" ];
                  cost = {
                    input = 0;
                    output = 0;
                    cacheRead = 0;
                    cacheWrite = 0;
                  };
                  contextWindow = 32768;
                  maxTokens = 32768;
                }
              ];
            };
          };
        };
      };
    };
  };
}
