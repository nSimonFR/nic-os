{ config, pkgs, inputs, username, ... }:
let defaultSinkId = "59";
in {
  imports = [
    inputs.zen-browser.homeModules.twilight
    ./packages.nix
    ./pipewire-noise.nix
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";

    sessionVariables = {
      QT_STYLE_OVERRIDE = "Adwaita-Dark";
      QT_QPA_PLATFORMTHEME = "qt5ct";

      WINE_FULLSCREEN = "1";
      WINE_FULLSCREEN_MODE = "3840,1600";
      WINE_FULLSCREEN_RECT = "0,0,3840,1600";
      XDG_SESSION_TYPE = "wayland";
      WAYLAND_DISPLAY = "wayland-1";

      # MANGOHUD = "1";
      # VK_INSTANCE_LAYERS = "VK_LAYER_MANGOHUD_overlay";
      # LD_PRELOAD = "${pkgs.mangohud}/lib/libMangoHud_opengl.so";

      SDL_JOYSTICK_HIDAPI = "0";
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

  services.xembed-sni-proxy.enable = true;

  services.hyprpaper = {
    enable = true;
    settings = {
      ipc = "on";
      preload = [ "~/wallpaper.png" ];
      wallpaper = [ ",~/wallpaper.png" ];
    };
  };

  programs.zen-browser = {
    enable = true;
    nativeMessagingHosts = [ pkgs.firefoxpwa ];
    policies = {
      DisableAppUpdate = true;
      DisableTelemetry = true;
    };
  };

  systemd.user.services.set-default-audio = {
    Unit = {
      Description = "Set default PipeWire audio output";
      After = [ "pipewire.service" ];
    };
    Service = {
      ExecStart = "${pkgs.wireplumber}/bin/wpctl set-default ${defaultSinkId}";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  xdg.portal.enable = true;

  xdg.configFile."hypr/hypridle.conf".source = ./dotfiles/hypr/hypridle.conf;
  xdg.configFile."hypr/hyprlock.conf".source = ./dotfiles/hypr/hyprlock.conf;
  xdg.configFile."dunst/dunstrc".source = ./dotfiles/dunstrc;
  xdg.configFile."MangoHud/MangoHud.conf".source = ./dotfiles/MangoHud.conf;
  xdg.configFile."alacritty/alacritty.toml".source = ./dotfiles/alacritty.toml;

  xdg.configFile."rofi" = {
    source = ./dotfiles/rofi;
    recursive = true;
  };

  xdg.configFile."waybar" = {
    source = ./dotfiles/waybar;
    recursive = true;
  };
}
