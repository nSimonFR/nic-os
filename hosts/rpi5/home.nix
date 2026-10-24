{
  inputs,
  pkgs,
  username,
  ...
}:
{
  imports = [
    ./hermes/hermes.nix
    ./mail.nix
  ];

  home.packages = with pkgs; [
    nodejs_22
    pnpm
    (callPackage ../../pkgs/cli/gogcli.nix { gogcli-src = inputs.gogcli-src; })
    (callPackage ../../pkgs/cli/goplaces.nix { goplaces-src = inputs.goplaces-src; })
    (callPackage ../../pkgs/cli/populartimes.nix { })
    (callPackage ../../pkgs/cli/entire.nix { })
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

}
