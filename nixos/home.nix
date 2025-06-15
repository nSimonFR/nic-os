{ config, pkgs, inputs, ... }:
{
  home = {
    # TODO use var
    username = "nsimon";
    homeDirectory = "/home/nsimon";

    packages = with pkgs; [
      # TODO sort A-Z
      rofi
      cliphist
      kitty
      _1password-gui
      docker
      slack
      spotify
      (discord.override {
        withOpenASAR = true;
        withVencord = true;
      })
      (writeShellScriptBin "discord-fixed" ''
        exec ${discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
      '')
    ];

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

  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = builtins.readFile ./hyprland.conf;
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
}
