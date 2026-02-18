{
  inputs,
  username,
  ...
}:
{
  imports = [
    ./openclaw.nix
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

}
