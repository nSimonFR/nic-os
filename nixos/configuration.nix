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

  # Minimal Hyprland config for greeter session — DPMS off after 5 min idle (WOL power saving)
  greeterHypridleConfig = pkgs.linkFarm "greeter-hypridle-config" [{
    name = "hypr/hypridle.conf";
    path = pkgs.writeText "hypridle.conf" ''
      listener {
        timeout = 300
        on-timeout = hyprctl dispatch dpms off
        on-resume = hyprctl dispatch dpms on
      }
    '';
  }];
  greeterHyprlandConfig = pkgs.writeText "greetd-hyprland.conf" ''
    monitor = desc:LG Electronics 38GN950 008NTKFBE741, 3840x1600@160, 0x0, 1
    monitor = desc:Acer Technologies GN246HL LW3EE0058532, disable
    monitor = , preferred, auto, 1
    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      key_press_enables_dpms = true
    }
    animations {
      enabled = false
    }
    exec-once = XDG_CONFIG_HOME=${greeterHypridleConfig} ${pkgs.hypridle}/bin/hypridle
    exec-once = ${pkgs.greetd.regreet}/bin/regreet; hyprctl dispatch exit
  '';

in
{
  imports = [
    ./hardware-configuration.nix
    ./rgb/openrgb-lg.nix # OpenRGB with LG monitor support
    ./rgb/hyperion-openrgb.nix # Hyperion with OpenRGB support
    ./rgb/hyperion-openrgb-bridge.nix # Bridge between Hyperion and OpenRGB
    ./piper-autoprofile.nix
    ./tobii-native.nix # Tobii Eye Tracker 5 native Linux (experimental)
    # Tailscale client configuration
    (import ../shared/tailscale.nix { role = "client"; enableSSH = true; })
  ];

  nixpkgs.config.allowUnfree = true;

  boot = {
    loader = {
      systemd-boot.enable = true;
      systemd-boot.configurationLimit = 15;
      efi.canTouchEfiVariables = true;
      efi.efiSysMountPoint = "/boot/efi";
    };

    kernelPackages = pkgs.linuxPackages_6_18; # 6.18.19 — NTSync support (6.14+), compatible with NVIDIA 580

    kernelParams = [
      "mem_sleep_default=s2idle"
      "nvidia.NVreg_PreserveVideoMemoryAllocations=0"
      "nvidia.NVreg_EnableGpuSuspend=1"
      "nvidia.NVreg_RegistryDwords=RMGpuTdr=0x7FFFFFFF" # Disable GPU TDR timeout (Star Citizen pipeline rebuild)
      "nvidia.NVreg_EnableGpuFirmware=0" # Disable GSP firmware (fixes Vulkan pipeline compile timeouts)
      "nvidia-drm.modeset=1" # CRITICAL: Required for NVIDIA on Wayland/Xwayland
      "nvidia-drm.fbdev=1" # Enable framebuffer device support
      "acpi_enforce_resources=lax" # Fix OpenRGB I2C/SMBus detection bug (GitLab issue #5059)
      "zswap.enabled=0" # Disable zswap when using zram (Star Citizen optimization)
      "transparent_hugepages=madvise" # Allow large memory apps (Star Citizen) to use 2MB pages, reducing TLB pressure
    ];

    kernel.sysctl = {
      "vm.max_map_count" = 16777216;
      "fs.file-max" = 524288;
      "vm.swappiness" = 100; # Use zram more aggressively
      "vm.dirty_ratio" = 5; # Cap dirty pages at ~1.6GB (was 6.4GB) to avoid write bursts on DRAM-less NVMe
      "vm.dirty_background_ratio" = 2; # Start flushing at ~640MB (was 3.2GB)
      "vm.dirty_expire_centisecs" = 1500; # Flush dirty pages after 15s (was 30s)
      "vm.dirty_writeback_centisecs" = 300; # Check for dirty pages every 3s (was 5s)
      "vm.min_free_kbytes" = 262144; # Keep 256MB free to prevent emergency reclaim I/O storms
    };

    kernelModules = [
      "ff_memless"
      "i2c-nvidia-gpu" # NVIDIA GPU I2C for RGB control
      "ntsync" # NT synchronization primitives for Wine/Proton (NTSync)
    ];

    supportedFilesystems = [ "ntfs3" ];

    # binfmt.emulatedSystems = [ "aarch64-linux" ]; # not needed — rpi5 builds natively via --build-host
  };

  # Star Citizen / LUG: hard open file limit (GE-Proton7-14-SC & LUG manual install)
  systemd.settings.Manager.DefaultLimitNOFILE = 524288;

  networking.hostName = "BeAsT";

  # Wake-on-LAN: allow magic-packet wake on the ethernet interface.
  # WOL is Layer 2 only — only devices on the same physical LAN (i.e. rpi5)
  # can send the magic packet; Tailscale and the internet cannot reach it.
  networking.interfaces.eno1.wakeOnLan.enable = true;

  time.timeZone = "Europe/Paris";

  # Wake-on-LAN: enable magic packet wake on the primary ethernet interface
  systemd.network.links."50-ethernet-wol" = {
    matchConfig.OriginalName = "eno*";
    linkConfig.WakeOnLan = "magic";
  };

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

  security.sudo.wheelNeedsPassword = false;

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
      "libvirtd" # VM management
      "kvm" # KVM acceleration
    ];
    home = "/home/${username}";

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd"
    ];
  };

  environment.systemPackages = with pkgs; [
    cage
    ddcutil
    ethtool # verify WoL: ethtool eno1 | grep Wake
    dmenu
    feh
    gamescope
    regreet
    i2c-tools
kdePackages.kwallet
    kdePackages.kwalletmanager
    libvirt # virsh CLI for VM management
    ntfs3g
    piper # GUI for Logitech G502 configuration (DPI, buttons, RGB)
    input-remapper # Remap keys/mouse buttons for games
    usbutils
    ethtool # verify WoL status: ethtool eno1 | grep Wake
    vim
    vulkan-tools
    vulkan-loader
    vulkan-validation-layers
    dxvk
    wayland
    wayland-protocols
    wget
    gamemode

    # WiFi utilities (available in PATH, no auto-connect)
    wpa_supplicant # wpa_passphrase, wpa_cli, wpa_supplicant
    iw             # modern wireless config (iw dev, iw scan …)
    wirelesstools  # iwconfig, iwlist, iwscan
    dhcpcd         # dhcp client for manual wifi sessions
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

  services.flatpak.enable = true;
  
  programs.hyprland.enable = true;

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
  programs.nix-ld = {
    enable = true;
    # Enable 32-bit support for pressure-vessel/Steam runtime
    libraries = with pkgs; [
      # 32-bit libraries for Steam/Proton/pressure-vessel
      pkgsi686Linux.glibc
    ];
  };

  # Symlink 32-bit dynamic linker for pressure-vessel compatibility
  environment.etc."ld-linux.so.2".source = "${pkgs.pkgsi686Linux.glibc}/lib/ld-linux.so.2";

  security.polkit.enable = true;

  # Cache polkit auth for 1Password (~5 min), similar to sudo behavior
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id === "com.1password.1Password.unlock" && subject.isInGroup("users")) {
        return polkit.Result.AUTH_SELF_KEEP;
      }
    });
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("com.feralinteractive.GameMode") === 0 && subject.isInGroup("users")) {
        return polkit.Result.YES;
      }
    });
    polkit.addRule(function(action, subject) {
      if (action.id === "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") === "ollama.service" &&
          subject.isInGroup("users")) {
        return polkit.Result.YES;
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
    open = false; # Proprietary modules: open modules have Vulkan pipeline compilation timeout bug (Xid 109)
    package = config.boot.kernelPackages.nvidiaPackages.production; # 580.119.02 — 590.x has Vulkan pipeline timeout

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

  # Use Hyprland instead of cage for greeter — enables hypridle DPMS (power saving after WOL)
  services.greetd.settings.default_session.command = lib.mkForce
    "${pkgs.dbus}/bin/dbus-run-session ${pkgs.hyprland}/bin/Hyprland --config ${greeterHyprlandConfig}";

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
        desiredgov = "performance";
        softrealtime = "auto";
        ioprio = 0;
      };
      gpu = {
        apply_gpu_optimisations = "accept-responsibility";
        gpu_device = 0;
        nv_powermizer_mode = 1;
      };
      custom = {
        start = toString (pkgs.writeShellScript "gamemode-start" ''
          ${pkgs.libnotify}/bin/notify-send 'GameMode started'
          ${pkgs.systemd}/bin/systemctl stop ollama || true
        '');
        end = toString (pkgs.writeShellScript "gamemode-end" ''
          ${pkgs.libnotify}/bin/notify-send 'GameMode ended'
          ${pkgs.systemd}/bin/systemctl start ollama
        '');
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
      "nofail"
      "x-systemd.automount"
      "noauto"
    ];
  };

  fileSystems."/mnt/media" = {
    device = "/dev/disk/by-label/Media\\x20HDD";
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

  # Disk swap disabled - using zram only for better performance
  swapDevices = [ ];

  zramSwap = {
    enable = true;
    memoryPercent = 100; # 32GB zram = ~64-96GB effective with compression
    algorithm = "zstd"; # Best compression ratio for Star Citizen
  };

  services.udev = {
    extraRules = ''
      # Input device access for seat management
      SUBSYSTEM=="input", GROUP="input", MODE="0660"
      KERNEL=="event*", GROUP="input", MODE="0660"
      KERNEL=="mouse*", GROUP="input", MODE="0660"

      # DualSense controller
      KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0666", TAG+="uaccess"

      # VKB devices for Star Citizen
      # Covers all VKB-Sim devices (Gladiator EVO L SEM, Gladiator EVO R, etc.)
      # TAG+="uaccess" on event/js nodes is required for Flatpak sandbox access
      # (group membership is lost in the Flatpak namespace, uaccess logind ACL is not)
      KERNEL=="hidraw*", ATTRS{idVendor}=="231d", ATTRS{idProduct}=="*", MODE="0660", TAG+="uaccess"
      KERNEL=="event*", ATTRS{idVendor}=="231d", TAG+="uaccess"
      KERNEL=="js*", ATTRS{idVendor}=="231d", TAG+="uaccess"

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

      # Tobii Eye Tracker 5 - Native Linux + VM passthrough with autosuspend disabled
      # Disable power management to ensure stable passthrough and adequate power delivery
      ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2104", ATTR{idProduct}=="0313", ATTR{power/control}="on", ATTR{power/autosuspend}="-1", MODE="0666", TAG+="uaccess"
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
    allowedUDPPorts = [ 4242 ]; # opentrack UDP from Tobii VM
  };

  virtualisation.docker = {
    enable = true;
  };

  # Libvirt/QEMU for Tobii Eye Tracker VM passthrough
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      swtpm.enable = true; # TPM emulation for Windows 11
      vhostUserPackages = [ pkgs.virtiofsd ]; # Required for virtiofs
    };
  };
  virtualisation.spiceUSBRedirection.enable = true;
  programs.virt-manager.enable = true;

  # Ollama - local LLM inference with CUDA (RTX 3080 Ti)
  # Gemma 4 26B-A4B: MoE with 3.8B active params, fits in 12GB VRAM at Q4, Arena ELO 1441
  # Qwen3.5-35B-A3B: MoE with 3B active params, highest benchmarks (85.3 MMLU-Pro), RAM offload
  services.ollama = {
    enable = true;
    package = (import inputs.nixpkgs-unstable {
      system = "x86_64-linux";
      config.allowUnfree = true;
      config.cudaSupport = true;
    }).ollama-cuda;
    host = "0.0.0.0"; # Bind all interfaces — firewalled to tailscale0 + localhost
    loadModels = [ "gemma4:26b" "gemma4:e4b" "qwen3.5:35b-a3b" ];
  };

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

  # ── DNS: use RPi5 blocky (ad/tracker/malware blocking) ──────────────
  # Primary = Tailscale (works everywhere), Fallback = LAN (home network)
  # Last-resort fallback to Cloudflare if RPi5 is completely unreachable
  networking.nameservers = [
    "100.122.54.2"   # RPi5 – Tailscale
  ];

  services.resolved = {
    enable = true;
    fallbackDns = [
      "1.1.1.1"        # Cloudflare – last resort if RPi5 is down
      "9.9.9.9"        # Quad9 – last resort
    ];
    # Don't let DHCP override our DNS settings
    dnsovertls = "opportunistic";
  };

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  # Required for Piper (mouse configuration GUI)
  services.ratbagd.enable = true;

  system.stateVersion = "25.11"; # DO NOT UPDATE UNLESS YOU KNOW WHAT YOU'RE DOING

  nix.settings = {
    trusted-users = [
      "root"
      username
    ];
    substituters = [
      "https://nix-citizen.cachix.org"
    ];
    trusted-public-keys = [
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

  # Limit journal size to 200MB
  services.journald.extraConfig = ''
    SystemMaxUse=200M
  '';

}
