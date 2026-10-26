{
  inputs,
  lib,
  pkgs,
  username,
  ...
}:
let
  # gh through Agent Vault (hosts/rpi5/agent-vault.nix), which attaches
  # nSimonFR-ai's token; gh only needs some token to think it is logged in.
  ghBrokered = pkgs.writeShellApplication {
    name = "gh";
    text = ''
      proxy=/var/lib/agent-vault-hermes/proxy.env
      if [ -r "$proxy" ]; then
        set -a
        # shellcheck source=/dev/null
        . "$proxy"
        set +a
        export GH_TOKEN=agent-vault
        unset GITHUB_TOKEN
      fi
      exec ${pkgs.gh}/bin/gh "$@"
    '';
  };
in
{
  imports = [
    ./hermes/hermes.nix
    ./mail.nix
  ];

  # No ~/.ssh/age here: that master key decrypts every secret in the repo,
  # Agent Vault's included. secrets-zsh (real Linear and Trusk tokens) is not
  # declared on this host at all.
  nic.userSecretsFromSystem = true;

  home.packages = with pkgs; [
    nodejs_22
    pnpm
    (callPackage ../../pkgs/cli/gogcli.nix { gogcli-src = inputs.gogcli-src; })
    (callPackage ../../pkgs/cli/goplaces.nix { goplaces-src = inputs.goplaces-src; })
    (callPackage ../../pkgs/cli/populartimes.nix { })
    (lib.hiPrio ghBrokered)
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

}
