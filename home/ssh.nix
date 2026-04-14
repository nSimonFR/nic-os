{ pkgs, ... }:
{
  programs.ssh = {
    enable = true;
    matchBlocks = {
      "*" = {
        extraOptions.IdentityAgent = "~/.bitwarden-ssh-agent.sock";
      };
      beast = {
        hostname = "beast";
        forwardAgent = true;
      };
      rpi5 = {
        hostname = "rpi5";
      };
      "github.com" = {
        hostname = "github.com";
        user = "git";
      };
    };
  };
}
