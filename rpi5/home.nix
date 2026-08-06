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
    (callPackage ../pkgs/gogcli.nix { gogcli-src = inputs.gogcli-src; })
    (callPackage ../pkgs/goplaces.nix { goplaces-src = inputs.goplaces-src; })
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

}
