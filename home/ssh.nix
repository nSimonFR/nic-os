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
        identityFile = "~/.ssh/id_ed25519";
        identitiesOnly = true;
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
