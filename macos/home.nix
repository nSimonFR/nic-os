{ username, ... }:
{
  imports = [
    ./applications-patch.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";

    sessionVariables = {
      # Bitwarden/Vaultwarden SSH agent (desktop app)
      SSH_AUTH_SOCK = "$HOME/.bitwarden-ssh-agent.sock";
    };
  };
}
