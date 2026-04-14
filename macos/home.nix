{ username, ... }:
{
  imports = [
    ./applications-patch.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";

    sessionVariables = {
      SSH_AUTH_SOCK = "$HOME/.bitwarden-ssh-agent.sock";
    };
  };
}
