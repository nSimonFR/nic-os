{
  config,
  pkgs,
  inputs,
  username,
  ...
}:
{
  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };
}
