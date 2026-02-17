{
  config,
  lib,
  pkgs,
  inputs,
  outputs,
  username,
  ...
}:
let
  # Toggle between LightDM (true) and ReGreet (false)
  useLightdm = false;

  hyprlandWrapper = pkgs.writeShellScriptBin "hyprland-nvidia" ''
    # NVIDIA-specific environment variables for Wayland
    export LIBVA_DRIVER_NAME=nvidia
    export GBM_BACKEND=nvidia-drm
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export WLR_NO_HARDWARE_CURSORS=1

    # Additional NVIDIA Wayland fixes
    export __GL_GSYNC_ALLOWED=1
    export __GL_VRR_ALLOWED=1

    # Run Hyprland
    exec ${pkgs.hyprland}/bin/Hyprland "$@"
  '';

  hyprlandSession =
    (pkgs.writeTextDir "share/wayland-sessions/hyprland.desktop" ''
      [Desktop Entry]
      Name=Hyprland
      Description=A dynamic tiling Wayland compositor
      Exec=${hyprlandWrapper}/bin/hyprland-nvidia
      Type=Application
    '').overrideAttrs
      (old: {
        passthru.providedSessions = [ "hyprland" ];
      });

  i3Session =
    (pkgs.writeTextDir "share/xsessions/i3.desktop" ''
      [Desktop Entry]
      Name=i3
      Comment=improved dynamic tiling window manager
      Exec=${pkgs.i3}/bin/i3
      Type=Application
      Keywords=tiling;wm;windowmanager;window;manager;
    '').overrideAttrs
      (old: {
        passthru.providedSessions = [ "i3" ];
      });
in
{
  imports = [
    # inputs.nix-gaming.nixosModules.platformOptimizations
    ./hardware-configuration.nix
    ./openrgb-lg.nix # OpenRGB with LG monitor support
    ./hyperion-openrgb.nix # Hyperion with OpenRGB support
    ./hyperion-openrgb-bridge.nix # Bridge between Hyperion and OpenRGB
    # Tailscale client configuration
    (import ../shared/tailscale.nix { role = "client"; })
  ];

  nixpkgs.config.allowUnfree = true;

  boot = {
    loader = {
      systemd-boot.enable = true;
      systemd-boot.configurationLimit = 15;
      efi.canTouchEfiVariables = true;
      efi.efiSysMountPoint = "/boot/efi";
    };

    kernelParams = [
      "mem_sleep_default=s2idle"
      "nvidia.NVreg_PreserveVideoMemoryAllocations=0"
      "nvidia.NVreg_EnableGpuSuspend=1"
      "nvidia-drm.modeset=1" # CRITICAL: Required for NVIDIA on Wayland/Xwayland
      "nvidia-drm.fbdev=1" # Enable framebuffer device support
      "acpi_enforce_resources=lax" # Fix OpenRGB I2C/SMBus detection bug (GitLab issue #5059)
    ];

    kernel.sysctl = {
      "vm.max_map_count" = 16777216;
      "fs.file-max" = 524288;
    };

    kernelModules = [
      "ff_memless"
      "i2c-nvidia-gpu" # NVIDIA GPU I2C for RGB control
    ];

    supportedFilesystems = [ "ntfs3" ];

    binfmt.emulatedSystems = [ "aarch64-linux" ];
  };

  # Star Citizen / LUG: hard open file limit (GE-Proton7-14-SC & LUG manual install)
  systemd.settings.Manager.DefaultLimitNOFILE = 524288;

  networking.hostName = "BeAsT";
  time.timeZone = "Europe/Paris";

  i18n = {
    defaultLocale = "en_US.UTF-8";
    #extraLocales = [ "fr_FR.utf8" ];
  };

  console = {
    # font = "Lat2-Terminus16";
    # keyMap = "us";
    useXkbConfig = true;
  };

  # Environment variables moved to hyprland.conf for Hyprland-specific setup

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [
      "wheel" # Enables 'sudo'
      "video"
      "audio"
      "disk"
      "networkmanager"
      "systemd-journal"
      "docker"
      "input"
      "seat" # Required for Wayland seat management
      "i2c" # Required for OpenRGB monitor control
    ];
    home = "/home/${username}";

    openssh.authorizedKeys.keys = [
      # TODO: fetch from github
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCfTlFbZh0ufzEysBxzaEhLU7A4J/n+c3ObaBr+nJPoovoBh9q4hB9KYwkr7y1wkkZgA6/aZqJu4HH2SCARGabyPJW2h2QY+IXs/pI7TV0eFaCP8SZjHWtz5rBm92pVSzXd/6/YoO+Ugn9EsuPYgnuGYlFaQ1BQrqCpJ7d+c9ZNU4mEKPNM5Ly/yo2V5Ox5nBfQg7jq9YIP0UFFwRe28Pi5OGCn0Wl+1aTOtd9sB06pXB4/CxCGRKZJLGe6QVMTFZJLObitjYpEX3zZ4Cj2MEiHVf6eubH0kTo6RSxYBZJBB2mmgBoDr9uae95LTXUBYoMPFb0dNYxzwe6HDZnqkBvlfsO6CHHAJYxqkRhxHgCy2gItJXpZ4HAPGezcnvBinTfuyf18Crb9wxiH5VaCaNaLhp66881KdLoMzNUTWU9L0ZRMzmabj0XgjpRLEqnTdvqq6H+NwYF1Avew07zwb8iZtbCIb2dxu653RxM8DwxmUnfmAAuxvxOoFpgYjDsDkahDEOynTkYWASbOoha66H5tU0mrAdeyooieHlFqAz/vjo5X/eIerWVrKEy0MdLx4Yu15ObTlWscU3qQyUmVlnH0SDg7ulH+4uNsXFE7jGHwg03MpYYAExTbPMpKlhJdaQI2Jzp3CcSqIG+1ODuPK8VcshTAtP0IrZ+ykFflB4EIcw=="
    ];
  };

  environment.systemPackages = with pkgs; [
    cage
    ddcutil
    dmenu
    feh
    gamescope
    regreet
    i2c-tools
    i3
    i3status
    kdePackages.kwallet
    kdePackages.kwalletmanager
    ntfs3g
    usbutils
    vim
    vulkan-tools
    vulkan-loader
    wayland
    wayland-protocols
    wget
    gamemode
  ];

  programs.kdeconnect.enable = true; # Enables KWallet D-Bus service

  # Enable PAM integration for KDE Wallet to auto-unlock on login
  security.pam.services.lightdm.enableKwallet = true;

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = false;
    pinentryPackage = pkgs.pinentry-curses;
  };

  services.printing.enable = true;

  services.openssh.enable = true;

  # services.flatpak.enable = true;
  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-hyprland
      pkgs.xdg-desktop-portal-gtk
    ];
    config.common.default = [
      "hyprland"
      "gtk"
    ];
  };
  programs.nix-ld.enable = true;

  security.polkit.enable = true;

  # Cache polkit auth for 1Password (~5 min), similar to sudo behavior
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id === "com.1password.1Password.unlock" && subject.isInGroup("users")) {
        return polkit.Result.AUTH_SELF_KEEP;
      }
    });
  '';

  # 1Password GUI with proper polkit integration
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ username ];
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  hardware.nvidia = {
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;

    modesetting.enable = true;
    nvidiaSettings = true;

    powerManagement = {
      enable = false;
      finegrained = false;
    };

    # Enable explicit sync for better Wayland support (requires driver >= 560)
    # This helps with Xwayland applications like games
    # Uncomment if you experience issues:
    forceFullCompositionPipeline = false;
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  programs.regreet = {
    enable = !useLightdm;
    theme = {
      package = pkgs.flat-remix-gtk;
      name = "Flat-Remix-GTK-Grey-Darkest";
    };
    settings = {
      background = {
        fit = "Cover";
        path = "/home/${username}/wallpaper.png";
      };
      GTK = {
        application_prefer_dark_theme = true;
      };
    };
  };

  users.users.greeter = {
    isSystemUser = true;
    group = "greeter";
  };
  users.groups.greeter = { };

  # Use LightDM instead - supports both X11 and Wayland sessions
  services.xserver.displayManager.lightdm = {
    enable = useLightdm;
    greeters.gtk = {
      enable = true;
      theme = {
        package = pkgs.flat-remix-gtk;
        name = "Flat-Remix-GTK-Grey-Darkest";
      };
      iconTheme = {
        package = pkgs.papirus-icon-theme;
        name = "Papirus-Dark";
      };
      cursorTheme = {
        package = pkgs.bibata-cursors;
        name = "Bibata-Modern-Classic";
        size = 16;
      };
      extraConfig = ''
        # Appearance
        font-name = Fira Code Nerd Font 11
        indicators = ~host;~spacer;~clock;~spacer;~session;~a11y;~power
        clock-format = %a %b %d, %H:%M

        # Background
        background = /home/${username}/wallpaper.png

        # Enable dark theme
        theme-name = Flat-Remix-GTK-Grey-Darkest
        icon-theme-name = Papirus-Dark
        cursor-theme-name = Bibata-Modern-Classic
        cursor-theme-size = 16

        # Colors and styling
        active-monitor = #cursor
        default-user-image = #avatar-default-symbolic
        hide-user-image = false

        # Keyboard
        keyboard = onboard
      '';
    };
  };

  # X server required for LightDM (but we use Wayland sessions)
  services.xserver = {
    enable = true;
  };

  # Enable libinput for proper mouse/touchpad support on Wayland
  services.libinput = {
    enable = true;
    mouse = {
      accelProfile = "flat";
      middleEmulation = false;
    };
  };

  services.displayManager.sessionPackages = [
    hyprlandSession
    i3Session
  ];

  environment.etc = {
    "1password/custom_allowed_browsers" = {
      # FIXME
      text = ''
        zen
        .zen-wrapped
        zen-twilight
        .zen-twilight-wrapped
      '';
      mode = "0755";
    };
    "dbus-1/system.conf".source = "${pkgs.dbus}/etc/dbus-1/system.conf";
    "dbus-1/session.conf".source = "${pkgs.dbus}/etc/dbus-1/session.conf";
  };

  security.pam.services.hyprlock = {
    allowNullPassword = false;
  };

  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  # Disable audio card power save to prevent crackling when waking from sleep
  # boot.extraModprobeConfig = ''
  #   options snd-hda-intel power_save=0 power_save_controller=N
  # '';

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    extest.enable = false; # Disabled due to 32-bit/64-bit library conflicts
    gamescopeSession.enable = true;
    localNetworkGameTransfers.openFirewall = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
    # platformOptimizations.enable = true;

    # Make gamemode available to Steam games
    package = pkgs.steam.override {
      extraLibraries = pkgs: [ pkgs.gamemode ];
    };
  };

  programs.gamemode = {
    enable = true;
    enableRenice = true;
    settings = {
      general = {
        renice = 10;
      };
      custom = {
        start = "${pkgs.libnotify}/bin/notify-send 'GameMode started'";
        end = "${pkgs.libnotify}/bin/notify-send 'GameMode ended'";
      };
    };
  };

  # Gamescope is installed as a regular package to avoid wrapper issues
  # programs.gamescope = {
  #   enable = true;
  #   capSysNice = false;
  # };

  hardware.steam-hardware.enable = true;

  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
    rulesProvider = pkgs.ananicy-cpp;
    extraRules = [
      {
        "name" = "gamescope";
        "nice" = -20;
      }
    ];
  };

  fileSystems."/mnt/games" = {
    device = "/dev/disk/by-label/Games\\x20SSD";
    fsType = "ntfs3";
    options = [
      "uid=1000"
      "gid=100"
      "umask=0000"
      "force"
      "nofail"
      "x-systemd.automount"
      "noauto"
    ];
  };

  fileSystems."/mnt/games-linux" = {
    device = "/dev/disk/by-label/Games-Linux";
    fsType = "ext4";
    options = [
      "uid=1000"
      "gid=100"
      "umask=0000"
      "force"
      "nofail"
      "x-systemd.automount"
      "noauto"
    ];
  };

  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 8 * 1024; # 8 GB Swap
    }
  ];

  zramSwap = {
    enable = true;
    memoryMax = 16 * 1024 * 1024 * 1024; # 16 GB ZRAM
  };

  services.udev = {
    extraRules = ''
      # Input device access for seat management
      SUBSYSTEM=="input", GROUP="input", MODE="0660"
      KERNEL=="event*", GROUP="input", MODE="0660"
      KERNEL=="mouse*", GROUP="input", MODE="0660"

      # DualSense controller
      KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0666", TAG+="uaccess"

      # OpenRGB USB HID device access for RGB keyboards/mice/devices
      # Drevo Calibur RGB Keyboard
      SUBSYSTEM=="usb", ENV{ID_VENDOR_ID}=="0483", ENV{ID_MODEL_ID}=="4010", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="4010", MODE="0666", TAG+="uaccess"

      # ASUS AURA LED Controller (motherboard RGB headers for fans)
      SUBSYSTEM=="usb", ENV{ID_VENDOR_ID}=="0b05", ENV{ID_MODEL_ID}=="19af", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="19af", MODE="0666", TAG+="uaccess"

      # Logitech G502 RGB Mouse
      SUBSYSTEM=="usb", ENV{ID_VENDOR_ID}=="046d", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{idVendor}=="046d", MODE="0666", TAG+="uaccess"

      # General OpenRGB USB access
      SUBSYSTEM=="hidraw", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTRS{idVendor}=="0b05", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTRS{idVendor}=="046d", TAG+="uaccess"
    '';

    packages = [ pkgs.game-devices-udev-rules ];
  };

  #system.activationScripts.applyWineDualsenseFix.text = builtins.readFile ./scripts/wine-dualsense-fix.sh;

  networking.firewall = rec {
    allowedTCPPortRanges = [
      {
        from = 1714;
        to = 1764;
      }
    ];
    allowedUDPPortRanges = allowedTCPPortRanges;
  };

  virtualisation.docker = {
    enable = true;
  };

  # Ollama - local LLM inference with CUDA (RTX 3080 Ti)
  # services.ollama = {
  #   enable = true;
  #   package = pkgs.ollama-cuda;
  #   loadModels = [ "qwen2.5:14b" ];
  # };

  services.hardware.openrgb = {
    enable = true;
    package = pkgs.openrgb-lg; # Use custom build with LG monitor support
    server.port = 6742; # Enable SDK server for screen-reactive effects
  };

  # Apply purple breathing RGB colors on startup
  # systemd.services.openrgb-colors = {
  #   description = "Apply OpenRGB color profile on startup";
  #   after = [ "openrgb.service" ];
  #   wants = [ "openrgb.service" ];
  #   wantedBy = [ "multi-user.target" ];
  #   serviceConfig = {
  #     Type = "oneshot";
  #     ExecStart = pkgs.writeShellScript "openrgb-apply-colors" ''
  #       # Wait for OpenRGB server to be fully ready
  #       sleep 3

  #       # Apply purple colors to all devices
  #       ${pkgs.openrgb-lg}/bin/openrgb --device 0 --mode direct --color FF00FF
  #       ${pkgs.openrgb-lg}/bin/openrgb --device 1 --mode direct --color FF00FF
  #       ${pkgs.openrgb-lg}/bin/openrgb --device 2 --mode static --color FF00FF
  #       ${pkgs.openrgb-lg}/bin/openrgb --device 3 --mode breathing --speed 80 --color FF00FF
  #       ${pkgs.openrgb-lg}/bin/openrgb --device 4 --mode breathing --speed 80 --color FF00FF
  #       ${pkgs.openrgb-lg}/bin/openrgb --device 5 --mode direct --color FF00FF
  #     '';
  #     RemainAfterExit = true;
  #   };
  # };

  # Enable DDC/CI for monitor control
  hardware.i2c.enable = true;

  services.dbus = {
    enable = true;
    implementation = "broker";
    packages = [ pkgs.dbus ];
  };

  hardware.uinput.enable = true;

  # Enable seat management for Wayland (critical for input device access)
  services.seatd = {
    enable = true;
    group = "seat";
  };

  services.resolved.enable = true;

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  system.stateVersion = "25.11"; # DO NOT UPDATE UNLESS YOU KNOW WHAT YOU'RE DOING

  nix.settings = {
    trusted-users = [
      "root"
      username
    ];
    substituters = [
      "https://nix-gaming.cachix.org"
      "https://nix-citizen.cachix.org"
    ];
    trusted-public-keys = [
      "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4="
      "nix-citizen.cachix.org-1:lPMkWc2X8XD4/7YPEEwXKKBg+SVbYTVrAaLA2wQTKCo="
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    download-buffer-size = 536870912;
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Home Manager — integrated so nixos-rebuild deploys user config too
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs outputs username;
      devSetup = false;
      unstablepkgs = import inputs.nixpkgs-unstable {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };
      masterpkgs = import inputs.nixpkgs-master {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };
    };
    users.${username} = {
      imports = [
        ../home
        ./home.nix
      ];
    };
  };
}
