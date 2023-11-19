{ inputs, lib, config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
  ];

  system = {
    stateVersion = "23.05";
    autoUpgrade.enable = true;
  };

  boot = {
    loader = {
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
      grub = {
        devices = [ "nodev" ];
        efiSupport = true;
        enable = true;
        extraEntries = ''
          menuentry "Windows" {
            insmod part_gpt
            insmod fat
            insmod search_fs_uuid
            insmod chain
            search --fs-uuid --set=root $FS_UUID
            chainloader /EFI/Microsoft/Boot/bootmgfw.efi
          }
        '';
      };
    };
    supportedFilesystems = [ "ntfs" ];
  };

  networking = {
    hostName = "BeAsT";
    networkmanager.enable = true;
  };

  nixpkgs = {
    config = {
      allowUnfree = true;
      pulseaudio = true;
    };
  };

  nix.settings = {
    experimental-features = "nix-command flakes";
    auto-optimise-store = true;
    substituters = ["https://nix-gaming.cachix.org"];
    trusted-public-keys = ["nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4="];
  };

  time = {
    timeZone = "Europe/Paris";
    hardwareClockInLocalTime = true;
  };

  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };
  fonts.fonts = with pkgs; [
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    font-awesome
    mplus-outline-fonts.githubRelease
    dina-font
    proggyfonts
  ];

  sound.enable = true;
  hardware = {
    opengl.driSupport32Bit = true;
    bluetooth.enable = true;
    bluetooth.powerOnBoot = true;
    pulseaudio.enable = true;
    pulseaudio.support32Bit = true;
    opengl.enable = true;
    nvidia.modesetting.enable = true;
  };

  fileSystems."/mnt/Games_SSD" = {
    device = "/dev/disk/by-label/Games\\x20SSD";
    fsType = "lowntfs-3g";
    options = [ "rw" "uid=nsimon" "gid=100" "user" "exec" "umast=000"];
  };

  services.blueman.enable = true;
  services.printing.enable = true;
  services.openssh.enable = true;
  services.gvfs.enable = true;
  services.xserver = {
    enable = true;
    videoDrivers = ["nvidia"];
    displayManager.gdm = {
      enable = true;
      wayland = true;
    };
  };

  environment.systemPackages = with pkgs; [
    home-manager
    vim
    pavucontrol
    firefox
    kitty
    waybar
    mako
    rofi
    swaylock
    pipewire
    wireplumber
  ];

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
    xwayland.hidpi = true;
    nvidiaPatches = true;
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  programs.zsh.enable = true;

  users.defaultUserShell = pkgs.zsh;
  users.users.nsimon = {
    isNormalUser = true;
    home = "/home/nsimon";
    extraGroups = [
      "wheel" # Enable ‘sudo’ for the user.
      "audio" # Enables pulseaudio management
    ];
  };
}
