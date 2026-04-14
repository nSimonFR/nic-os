{ pkgs, ... }:
{
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "*" = {
        forwardAgent = true;
        extraOptions.IdentityAgent = "~/.bitwarden-ssh-agent.sock";
      };
    };
  };
}
