{ username, ... }:
{
  imports = [
    ./applications-patch.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";
  };
}
