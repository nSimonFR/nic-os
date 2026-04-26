{ pkgs, ... }:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        forwardAgent = true;
        extraOptions.IdentityAgent = "~/.bitwarden-ssh-agent.sock";
      };
    };
  };
}
