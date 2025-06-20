{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  nixpkgs.config.allowUnfree = true;

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
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

  users.users.nsimon = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
    home = "/home/nsimon";

    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCfTlFbZh0ufzEysBxzaEhLU7A4J/n+c3ObaBr+nJPoovoBh9q4hB9KYwkr7y1wkkZgA6/aZqJu4HH2SCARGabyPJW2h2QY+IXs/pI7TV0eFaCP8SZjHWtz5rBm92pVSzXd/6/YoO+Ugn9EsuPYgnuGYlFaQ1BQrqCpJ7d+c9ZNU4mEKPNM5Ly/yo2V5Ox5nBfQg7jq9YIP0UFFwRe28Pi5OGCn0Wl+1aTOtd9sB06pXB4/CxCGRKZJLGe6QVMTFZJLObitjYpEX3zZ4Cj2MEiHVf6eubH0kTo6RSxYBZJBB2mmgBoDr9uae95LTXUBYoMPFb0dNYxzwe6HDZnqkBvlfsO6CHHAJYxqkRhxHgCy2gItJXpZ4HAPGezcnvBinTfuyf18Crb9wxiH5VaCaNaLhp66881KdLoMzNUTWU9L0ZRMzmabj0XgjpRLEqnTdvqq6H+NwYF1Avew07zwb8iZtbCIb2dxu653RxM8DwxmUnfmAAuxvxOoFpgYjDsDkahDEOynTkYWASbOoha66H5tU0mrAdeyooieHlFqAz/vjo5X/eIerWVrKEy0MdLx4Yu15ObTlWscU3qQyUmVlnH0SDg7ulH+4uNsXFE7jGHwg03MpYYAExTbPMpKlhJdaQI2Jzp3CcSqIG+1ODuPK8VcshTAtP0IrZ+ykFflB4EIcw=="
    ];
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    cage
    ntfs3g
  ];

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    pinentryPackage = pkgs.pinentry-curses;
    defaultCacheTtl = 315569520;
    maxCacheTtl = 315569520;
  };

  services.printing.enable = true;

  services.openssh.enable = true;

  hardware.graphics.enable = true;

  hardware.nvidia = {
    modesetting.enable = true;
    open = true;
    nvidiaSettings = true;

    powerManagement = {
      enable = false;
      finegrained = false;
    };

    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  security.polkit.enable = true;

  services.xserver.videoDrivers = ["nvidia"];

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "hyprland";
        user = "nsimon";
      };
    };
  };

  services.pipewire = {
    enable = true;
    pulse.enable = true;
  };

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
  };
  hardware.steam-hardware.enable = true;

  fileSystems."/mnt/games" = {
    device = "/dev/disk/by-label/Games\\x20SSD";
    fsType = "ntfs3";
    options = [ "uid=1000" "gid=100" "umask=0000" ];
  };

  system.stateVersion = "25.05"; # DO NOT UPDATE UNLESS YOU KNOW WHAT YOU'RE DOING

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}

