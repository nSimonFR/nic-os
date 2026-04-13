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
    $DRY_RUN_CMD mkdir -p /home/${username}/.cache/nvidia-shader-cache/star-citizen
    ${pkgs.flatpak}/bin/flatpak override --user io.github.mactan_sc.RSILauncher \
      --filesystem=/nix/store:ro \
      --filesystem=/run/current-system:ro \
      --filesystem=/home/${username}/mangohud-logs \
      --filesystem=/home/${username}/.cache/nvidia-shader-cache/star-citizen \
      --env=__GL_SHADER_DISK_CACHE_PATH=/home/${username}/.cache/nvidia-shader-cache/star-citizen \
      --talk-name=com.feralinteractive.GameMode

    # Pin GNOME Platform 49 runtime: the RSI Launcher Flatpak ships GNOME 48 (EOL)
    # which bundles libwayland-client 1.23.1. The host runs wayland 1.24.0 and the
    # mismatch causes the Wayland client to segfault — wine creates surfaces but
    # no window appears in the compositor. GNOME 49 ships wayland 1.24.0.
    # `flatpak override` doesn't support [Application] section, so write it directly.
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -Dm644 /dev/stdin \
      /home/${username}/.local/share/flatpak/overrides/io.github.mactan_sc.RSILauncher <<FLATPAK_OVERRIDE
    [Application]
    runtime=org.gnome.Platform/x86_64/49

    [Context]
    filesystems=/nix/store:ro;/run/current-system:ro;/home/${username}/mangohud-logs;/home/${username}/.cache/nvidia-shader-cache/star-citizen;xdg-config/MangoHud:ro;!/run/opengl-driver;

    [Session Bus Policy]
    com.feralinteractive.GameMode=talk

    [Environment]
    __GL_SHADER_DISK_CACHE_PATH=/home/${username}/.cache/nvidia-shader-cache/star-citizen
    FLATPAK_OVERRIDE
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

  home.packages = [
    (pkgs.btop.override { cudaSupport = true; })
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

      # Bitwarden/Vaultwarden SSH agent (desktop app)
      SSH_AUTH_SOCK = "$HOME/.bitwarden-ssh-agent.sock";

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

  home.file."wallpaper.png".source = ./dotfiles/wallpaper.png;

  # Cache GPG passphrase for ~400 days so git commit signing doesn't prompt every time
  home.file.".gnupg/gpg-agent.conf".text = ''
    default-cache-ttl 2592000
    max-cache-ttl 2592000
  '';

  xdg.configFile."hypr/hypridle.conf".source = ./dotfiles/hypr/hypridle.conf;
  xdg.configFile."hypr/hyprlock.conf".source = ./dotfiles/hypr/hyprlock.conf;
  xdg.configFile."dunst/dunstrc".source = ./dotfiles/dunstrc;
  xdg.configFile."MangoHud/MangoHud.conf".source = ./dotfiles/MangoHud.conf;
  xdg.configFile."alacritty/alacritty.toml".source = ./dotfiles/alacritty.toml;
  # Ghostty config is managed in shared home/default.nix via xdg.configFile

  # MangoHud config for RSILauncher Flatpak (reads from Flatpak-specific XDG_CONFIG_HOME)
  home.file.".var/app/io.github.mactan_sc.RSILauncher/config/MangoHud/MangoHud.conf".source = ./dotfiles/MangoHud.conf;
    # Override the flatpak-exported desktop entry to launch with gamemode.
  # Must use xdg.dataFile (→ $XDG_DATA_HOME/applications/) rather than
  # xdg.desktopEntries (→ home-manager profile in $XDG_DATA_DIRS) because the
  # Flatpak-exported entry appears earlier in $XDG_DATA_DIRS and would otherwise
  # take precedence over the home-manager profile path.
  xdg.dataFile."applications/io.github.mactan_sc.RSILauncher.desktop".text = ''
    [Desktop Entry]
    Categories=Game
    Comment=RSI Launcher
    Exec=flatpak run --command=gamemoderun io.github.mactan_sc.RSILauncher rsi-run
    GenericName=RSI Launcher
    Icon=io.github.mactan_sc.RSILauncher
    Keywords=Star Citizen;StarCitizen;
    Name=RSI Launcher
    StartupNotify=true
    Terminal=false
    Type=Application
    Version=1.5
    X-Flatpak=io.github.mactan_sc.RSILauncher
    X-Flatpak-Tags=proprietary;
  '';

  xdg.configFile."rofi-rbw.rc".source = ./dotfiles/rofi-rbw.rc;

  xdg.configFile."rofi" = {
    source = ./dotfiles/rofi;
    recursive = true;
  };

  xdg.configFile."waybar" = {
    source = ./dotfiles/waybar;
    recursive = true;
  };
}
