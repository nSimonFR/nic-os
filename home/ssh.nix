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
      trusk-sftp = {
        hostname = "sftp.trusk.com";
        user = "nicolas_simon";
      };
      trusk-sftp-server-w0bc = {
        user = "nicolas_simon_trusk_com";
        proxyJump = "bastion.trusk.com";
      };
    };
  };
}
