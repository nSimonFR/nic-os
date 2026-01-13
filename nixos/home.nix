{
  config,
  pkgs,
  inputs,
  username,
  ...
}:
{
  imports = [
    inputs.zen-browser.homeModules.twilight
    ./packages.nix
    ./audio.nix
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";

    sessionVariables = {
      QT_STYLE_OVERRIDE = "Adwaita-Dark";
      QT_QPA_PLATFORMTHEME = "qt5ct";

      # Vulkan shader cache size (increase from default ~1GB to 10GB)
      "MESA_SHADER_CACHE_MAX_SIZE" = "10G";
      "MESA_DISK_CACHE_MAX_SIZE" = "10G";

      # NVIDIA shader cache size (10GB = 10737418240 bytes)
      "__GL_SHADER_DISK_CACHE_SIZE" = "10737418240";
      "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP" = "1";
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
      name = "Fira Code Nerd Font";
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
    extraConfig = builtins.readFile ./dotfiles/hypr/hyprland.conf;
  };

  # services.xembed-sni-proxy.enable = true;

  services.hyprpaper = {
    enable = true;
    settings = {
      ipc = "on";
      preload = [ "~/wallpaper.png" ];
      wallpaper = [
        "desc:LG Electronics 38GN950 008NTKFBE741,~/wallpaper.png"
        "desc:Acer Technologies GN246HL LW3EE0058532,~/wallpaper.png"
      ];
    };
  };

  programs.zen-browser = {
    enable = true;
    # nativeMessagingHosts = [ pkgs."1password" ];
    policies = {
      DisableAppUpdate = true;
      DisableTelemetry = true;
    };
  };

  # xdg.portal = {
  #   enable = true;
  #   extraPortals = with pkgs; [
  #     xdg-desktop-portal-hyprland
  #     xdg-desktop-portal-gtk
  #   ];
  #   config.common.default = "*";
  # };

  xdg.configFile."hypr/hypridle.conf".source = ./dotfiles/hypr/hypridle.conf;
  xdg.configFile."hypr/hyprlock.conf".source = ./dotfiles/hypr/hyprlock.conf;
  xdg.configFile."dunst/dunstrc".source = ./dotfiles/dunstrc;
  xdg.configFile."MangoHud/MangoHud.conf".source = ./dotfiles/MangoHud.conf;
  xdg.configFile."alacritty/alacritty.toml".source = ./dotfiles/alacritty.toml;
  xdg.configFile."i3/config".source = ./dotfiles/i3/config;
  xdg.configFile."i3status/config".source = ./dotfiles/i3/i3status.conf;
  xdg.configFile."kitty/kitty.conf".source = ./dotfiles/kitty/kitty.conf;

  xdg.configFile."rofi" = {
    source = ./dotfiles/rofi;
    recursive = true;
  };

  xdg.configFile."waybar" = {
    source = ./dotfiles/waybar;
    recursive = true;
  };
}
