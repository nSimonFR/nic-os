{config, pkgs, ...}: {
  wayland.windowManager.hyprland.extraConfig = (builtins.readFile ./hyprland.conf);
}