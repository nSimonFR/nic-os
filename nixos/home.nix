{ username, hyprland, ... }:
{
  imports = [
    hyprland.homeManagerModules.default
    ../home/hyprland
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

  systemd.user.startServices = "sd-switch";
}
