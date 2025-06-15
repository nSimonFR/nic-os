{ config, pkgs, inputs, username, ... }:
{
  imports = [
    ./hyprpaper.nix
    ./packages.nix
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";

    sessionVariables = {
      QT_STYLE_OVERRIDE = "Adwaita-Dark";
      QT_QPA_PLATFORMTHEME = "qt5ct";
    };

    pointerCursor = {
      gtk.enable = true;
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 16;
    };
  };

  gtk = {
    enable = true;

    theme = {
      package = pkgs.flat-remix-gtk;
      name = "Flat-Remix-GTK-Grey-Darkest";
    };

    iconTheme = {
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
    };

    font = {
      name = "Sans";
      size = 11;
    };
  };

  qt = {
    enable = true;
    platformTheme.name = "qt5ct";
    style.name = "Adwaita-Dark";
  };

  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = builtins.readFile ./hyprland.conf;
  };
}
