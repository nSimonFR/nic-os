{ username, pkgs, ... }:
{
  imports = [
    ./applications-patch.nix
  ];

  # litellm proxy: translates Anthropic API format → Ollama, used by claude-local alias
  launchd.agents."litellm-ollama" = {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.litellm}/bin/litellm"
        "--model" "ollama_chat/gemma4:26b"
        "--port" "4000"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardErrorPath = "/tmp/litellm-ollama.log";
      StandardOutPath = "/tmp/litellm-ollama.log";
    };
  };

  # litellm proxy: routes to Beast's Ollama (RTX 3080 Ti, CUDA) via Tailscale, used by claude-beast alias
  launchd.agents."litellm-beast" = {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.litellm}/bin/litellm"
        "--model" "ollama_chat/gemma4:26b"
        "--port" "4001"
        "--api_base" "http://beast:11434"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardErrorPath = "/tmp/litellm-beast.log";
      StandardOutPath = "/tmp/litellm-beast.log";
    };
  };

  home = {
    username = username;
    homeDirectory = "/Users/${username}";

    sessionVariables = {
      # Bitwarden/Vaultwarden SSH agent (desktop app)
      SSH_AUTH_SOCK = "$HOME/.bitwarden-ssh-agent.sock";
    };
  };
}
