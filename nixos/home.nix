{
  config,
  lib,
  pkgs,
  inputs,
  username,
  ...
}:
{
  imports = [
    inputs.zen-browser.homeModules.twilight
    inputs.nix-flatpak.homeManagerModules.nix-flatpak
    ./packages.nix
    ./audio.nix
  ];

  # Grant RSILauncher access to:
  # - /nix/store:ro  so Wine can load NPClient64.dll from its nix store path
  # - /run/current-system:ro  so Z:/run/current-system/sw/libexec/opentrack/ is reachable inside the sandbox
  # The Flatpak already has shared=ipc which covers POSIX shared memory for the TrackIR file mapping.
  home.activation.rsiLauncherFlatpakOverrides = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.flatpak}/bin/flatpak override --user io.github.mactan_sc.RSILauncher \
      --filesystem=/nix/store:ro \
      --filesystem=/run/current-system:ro \
      --filesystem=/home/${username}/mangohud-logs
  '';

  services.flatpak.remotes = [
    {
      name = "RSILauncher";
      location = "https://mactan-sc.github.io/rsilauncher/RSILauncher.flatpakrepo";
    }
  ];

  services.flatpak.packages = [
    { appId = "io.github.mactan_sc.RSILauncher"; origin = "RSILauncher"; }
    { appId = "org.freedesktop.Platform.VulkanLayer.MangoHud"; origin = "flathub"; }
  ];

  programs.zsh.zplug.plugins = [
    { name = "MichaelAquilina/zsh-auto-notify"; }
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";

    sessionVariables = {
      QT_STYLE_OVERRIDE = "Adwaita-Dark";
      QT_QPA_PLATFORMTHEME = "qt5ct";

      # Make Electron apps (Cursor, Discord, Slack, etc.) use native Wayland
      # This fixes clipboard copy/paste between Electron apps and Wayland
      ELECTRON_OZONE_PLATFORM_HINT = "auto";
      NIXOS_OZONE_WL = "1";

      # 1Password SSH agent
      SSH_AUTH_SOCK = "$HOME/.1password/agent.sock";

      # Vulkan shader cache size (increase from default ~1GB to 10GB)
      "MESA_SHADER_CACHE_MAX_SIZE" = "10G";
      "MESA_DISK_CACHE_MAX_SIZE" = "10G";

      # NVIDIA shader cache size (10GB = 10737418240 bytes)
      "__GL_SHADER_DISK_CACHE" = "1";
      "__GL_SHADER_DISK_CACHE_SIZE" = "10737418240";
      "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP" = "1";

      # Wine sync (ESync/FSync) - improves game performance
      "WINEESYNC" = "1";
      "WINEFSYNC" = "1";
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

  # XDG portal is enabled at the system level in configuration.nix

  # Cache GPG passphrase for ~400 days so git commit signing doesn't prompt every time
  home.file.".gnupg/gpg-agent.conf".text = ''
    default-cache-ttl 2592000
    max-cache-ttl 2592000
  '';

  xdg.configFile."hypr/hypridle.conf".source = ./dotfiles/hypr/hypridle.conf;
  xdg.configFile."hypr/hyprlock.conf".source = ./dotfiles/hypr/hyprlock.conf;
  xdg.configFile."dunst/dunstrc".source = ./dotfiles/dunstrc;
  xdg.configFile."MangoHud/MangoHud.conf".source = ./dotfiles/MangoHud.conf;
  # MangoHud config for RSILauncher Flatpak (reads from Flatpak-specific XDG_CONFIG_HOME)
  home.file.".var/app/io.github.mactan_sc.RSILauncher/config/MangoHud/MangoHud.conf".source = ./dotfiles/MangoHud.conf;
  xdg.configFile."alacritty/alacritty.toml".source = ./dotfiles/alacritty.toml;
  # Ghostty config is managed in shared home/default.nix via xdg.configFile

  xdg.configFile."rofi" = {
    source = ./dotfiles/rofi;
    recursive = true;
  };

  xdg.configFile."waybar" = {
    source = ./dotfiles/waybar;
    recursive = true;
  };
}
