{ config, lib, pkgs, inputs, username, ... }:
let
  hyprlandSession =
    (pkgs.writeTextDir "share/wayland-sessions/hyprland.desktop" ''
      [Desktop Entry]
      Name=Hyprland
      Description=A dynamic tiling Wayland compositor
      Exec=${pkgs.hyprland}/bin/Hyprland
      Type=Application
    '').overrideAttrs (old: { passthru.providedSessions = [ "hyprland" ]; });
in {
  imports = [
    inputs.nix-gaming.nixosModules.platformOptimizations
    ./hardware-configuration.nix
  ];

  nixpkgs.config.allowUnfree = true;

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    kernelParams = [
      "mem_sleep_default=s2idle"
      "nvidia.NVreg_PreserveVideoMemoryAllocations=0"
      "nvidia.NVreg_EnableGpuSuspend=1"
    ];

    # kernel.sysctl = {
    #   "vm.max_map_count" = 16777216;
    #   "fs.file-max" = 524288;
    # };

    kernelModules = [ "ff_memless" ];

    supportedFilesystems = [ "ntfs3" ];
  };

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
    ];
    home = "/home/${username}";

    openssh.authorizedKeys.keys = [
      # TODO: fetch from github
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCfTlFbZh0ufzEysBxzaEhLU7A4J/n+c3ObaBr+nJPoovoBh9q4hB9KYwkr7y1wkkZgA6/aZqJu4HH2SCARGabyPJW2h2QY+IXs/pI7TV0eFaCP8SZjHWtz5rBm92pVSzXd/6/YoO+Ugn9EsuPYgnuGYlFaQ1BQrqCpJ7d+c9ZNU4mEKPNM5Ly/yo2V5Ox5nBfQg7jq9YIP0UFFwRe28Pi5OGCn0Wl+1aTOtd9sB06pXB4/CxCGRKZJLGe6QVMTFZJLObitjYpEX3zZ4Cj2MEiHVf6eubH0kTo6RSxYBZJBB2mmgBoDr9uae95LTXUBYoMPFb0dNYxzwe6HDZnqkBvlfsO6CHHAJYxqkRhxHgCy2gItJXpZ4HAPGezcnvBinTfuyf18Crb9wxiH5VaCaNaLhp66881KdLoMzNUTWU9L0ZRMzmabj0XgjpRLEqnTdvqq6H+NwYF1Avew07zwb8iZtbCIb2dxu653RxM8DwxmUnfmAAuxvxOoFpgYjDsDkahDEOynTkYWASbOoha66H5tU0mrAdeyooieHlFqAz/vjo5X/eIerWVrKEy0MdLx4Yu15ObTlWscU3qQyUmVlnH0SDg7ulH+4uNsXFE7jGHwg03MpYYAExTbPMpKlhJdaQI2Jzp3CcSqIG+1ODuPK8VcshTAtP0IrZ+ykFflB4EIcw=="
    ];
  };

  environment.systemPackages = with pkgs; [
    cage
    greetd.regreet
    ntfs3g
    openrgb-with-all-plugins
    usbutils
    vim
    vulkan-tools
    vulkan-loader
    wayland
    wayland-protocols
    wget
  ];

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  services.printing.enable = true;

  services.openssh.enable = true;

  security.polkit.enable = true;

  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;

  hardware.nvidia = {
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;

    modesetting.enable = true;
    nvidiaSettings = true;

    powerManagement = {
      enable = false;
      finegrained = false;
    };
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command =
          "${pkgs.cage}/bin/cage -m last -s ${pkgs.greetd.regreet}/bin/regreet";
        user = "greeter";
      };
    };
  };

  programs.regreet = {
    enable = true;

    theme = {
      package = pkgs.flat-remix-gtk;
      name = "Flat-Remix-GTK-Grey-Darkest";
    };

    settings = {
      background = {
        fit = "Cover";
        path = "/home/${username}/wallpaper.png";
      };
      GTK = { application_prefer_dark_theme = true; };
    };
  };

  users.users.greeter = {
    isSystemUser = true;
    group = "greeter";
  };

  services.displayManager.sessionPackages = [ hyprlandSession ];

  environment.etc = {
    "1password/custom_allowed_browsers" = {
      # FIXME
      text = ''
        zen-twilight
      '';
      mode = "0755";
    };
  };

  security.pam.services.hyprlock = { allowNullPassword = false; };

  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    extest.enable = true;
    gamescopeSession.enable = true;
    localNetworkGameTransfers.openFirewall = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
    platformOptimizations.enable = true;
  };

  programs.gamemode.enable = true;

  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  hardware.steam-hardware.enable = true;

  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
    rulesProvider = pkgs.ananicy-cpp;
    extraRules = [{
      "name" = "gamescope";
      "nice" = -20;
    }];
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

  swapDevices = [{
    device = "/var/lib/swapfile";
    size = 8 * 1024; # 8 GB Swap
  }];

  zramSwap = {
    enable = true;
    memoryMax = 16 * 1024 * 1024 * 1024; # 16 GB ZRAM
  };

  services.udev = {
    extraRules = ''
      SUBSYSTEM=="input", GROUP="input", MODE="0660"
      KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0666", TAG+="uaccess"
    '';

    packages = [ pkgs.game-devices-udev-rules ];
  };

  #system.activationScripts.applyWineDualsenseFix.text = builtins.readFile ./scripts/wine-dualsense-fix.sh;

  networking.firewall = rec {
    allowedTCPPortRanges = [{
      from = 1714;
      to = 1764;
    }];
    allowedUDPPortRanges = allowedTCPPortRanges;
  };

  virtualisation.docker = { enable = true; };

  services.hardware.openrgb.enable = true;

  services.dbus.enable = true;
  hardware.uinput.enable = true;

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  system.stateVersion =
    "25.05"; # DO NOT UPDATE UNLESS YOU KNOW WHAT YOU'RE DOING

  nix.settings = {
    substituters = [ "https://nix-gaming.cachix.org" ];
    trusted-public-keys = [
      "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4="
    ];
    experimental-features = [ "nix-command" "flakes" ];
  };
}

