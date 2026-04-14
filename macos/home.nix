{ username, ... }:
{
  imports = [
    ./applications-patch.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";

    sessionVariables = {
      # 1Password SSH agent
      SSH_AUTH_SOCK = "$HOME/.1password/agent.sock";
    };
  };
}
