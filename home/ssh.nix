{ lib, host, ... }:
{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      "*" = {
        forwardAgent = true;
        # The Bitwarden *desktop* app provides this socket. Pointing at it on a
        # host that doesn't run the desktop app (the headless rpi5) doesn't fall
        # back — IdentityAgent overrides SSH_AUTH_SOCK, so it takes the agent
        # away. The Pi uses gpg-agent's SSH support instead (see
        # hosts/rpi5/configuration.nix).
        extraOptions = lib.optionalAttrs host.isGraphical {
          IdentityAgent = "~/.bitwarden-ssh-agent.sock";
        };
      };
    };
  };
}
