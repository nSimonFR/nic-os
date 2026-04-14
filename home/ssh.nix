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
        user = "nsimon";
        forwardAgent = true;
      };
      "192.168.1.100" = {
        user = "nsimon";
        # proxyJump = "beast";
        forwardAgent = true;
      };
      rpi5 = {
        hostname = "192.168.1.68";
        user = "nsimon";
      };
      "github.com" = {
        hostname = "github.com";
        user = "git";
      };
    };
  };
}
