{ inputs, lib, config, pkgs, username, ... }:
{
  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

  systemd.user.startServices = "sd-switch";
}
