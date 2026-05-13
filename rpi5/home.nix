{
  inputs,
  pkgs,
  username,
  ...
}:
{
  imports = [
    ./picoclaw/picoclaw.nix
  ];

  home.packages = with pkgs; [
    nodejs_22
    pnpm
    vdirsyncer
    khal
    himalaya
    (callPackage ./gogcli.nix { gogcli-src = inputs.gogcli-src; })
    (callPackage ./goplaces.nix { goplaces-src = inputs.goplaces-src; })
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

}
