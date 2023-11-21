{ username, ... }:
{
  imports = [
    ./applications-patch.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";
  };

  xdg.configFile."nix/nix.conf".text = ''
    experimental-features = nix-command flakes
  '';
}
