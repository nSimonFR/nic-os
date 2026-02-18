{
  config,
  pkgs,
  inputs,
  outputs,
  username,
  nixos-raspberrypi,
  ...
}:
let
  system = "aarch64-linux";
in
{
  imports = with nixos-raspberrypi.nixosModules; [
    raspberry-pi-5.base
    raspberry-pi-5.page-size-16k
    raspberry-pi-5.bluetooth
    ./home-assistant.nix
    ./firefly-iii.nix
    ./blocky.nix
    # Tailscale with server features (subnet routing, SSH, exit node)
    (import ../shared/tailscale.nix {
      role = "server";
      enableSSH = true;
      advertiseExitNode = true;
    })
  ];

  nixpkgs.config.allowUnfree = true;

  boot.loader.raspberry-pi.bootloader = "kernel";

  networking = {
    hostName = "rpi5";
    useNetworkd = true;
    firewall.allowedUDPPorts = [
      9 # Wake-on-LAN
    ];
    wireless.iwd = {
      enable = true;
      settings = {
        Network = {
          EnableIPv6 = true;
          RoutePriorityOffset = 300;
        };
        Settings.AutoConnect = true;
      };
    };
  };

  services.resolved.enable = true;

  # Wake-on-LAN: enable magic packet wake on the ethernet interface
  systemd.network.links."50-ethernet-wol" = {
    matchConfig.OriginalName = "end*";
    linkConfig.WakeOnLan = "magic";
  };

  time.timeZone = "Europe/Paris";

  i18n.defaultLocale = "en_US.UTF-8";

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  users.users.${username} = {
    isNormalUser = true;
    initialPassword = "changeme";
    extraGroups = [
      "wheel"
      "video"
      "networkmanager"
      "docker"
    ];
    home = "/home/${username}";
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCfTlFbZh0ufzEysBxzaEhLU7A4J/n+c3ObaBr+nJPoovoBh9q4hB9KYwkr7y1wkkZgA6/aZqJu4HH2SCARGabyPJW2h2QY+IXs/pI7TV0eFaCP8SZjHWtz5rBm92pVSzXd/6/YoO+Ugn9EsuPYgnuGYlFaQ1BQrqCpJ7d+c9ZNU4mEKPNM5Ly/yo2V5Ox5nBfQg7jq9YIP0UFFwRe28Pi5OGCn0Wl+1aTOtd9sB06pXB4/CxCGRKZJLGe6QVMTFZJLObitjYpEX3zZ4Cj2MEiHVf6eubH0kTo6RSxYBZJBB2mmgBoDr9uae95LTXUBYoMPFb0dNYxzwe6HDZnqkBvlfsO6CHHAJYxqkRhxHgCy2gItJXpZ4HAPGezcnvBinTfuyf18Crb9wxiH5VaCaNaLhp66881KdLoMzNUTWU9L0ZRMzmabj0XgjpRLEqnTdvqq6H+NwYF1Avew07zwb8iZtbCIb2dxu653RxM8DwxmUnfmAAuxvxOoFpgYjDsDkahDEOynTkYWASbOoha66H5tU0mrAdeyooieHlFqAz/vjo5X/eIerWVrKEy0MdLx4Yu15ObTlWscU3qQyUmVlnH0SDg7ulH+4uNsXFE7jGHwg03MpYYAExTbPMpKlhJdaQI2Jzp3CcSqIG+1ODuPK8VcshTAtP0IrZ+ykFflB4EIcw=="
    ];
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  # ── Fail2ban: ban IPs after repeated failed auth attempts ──────────
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment = {
      enable = true; # double ban time on repeat offenders
      maxtime = "48h";
    };
    jails.sshd = {
      settings = {
        enabled = true;
        filter = "sshd";
        maxretry = 3;
      };
    };
  };

  # ── Automatic updates: pull from GitHub and rebuild daily ──────────
  system.autoUpgrade = {
    enable = true;
    flake = "github:nSimonFR/nic-os#rpi5";
    dates = "04:00";
    randomizedDelaySec = "30min";
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "06:00";
    };
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    usbutils
    tree
    ethtool # useful to verify WoL status: ethtool end0 | grep Wake
  ];

  virtualisation.docker.enable = true;

  # Create /bin/mkdir and /bin/ln for nix-openclaw compatibility
  # (the module hardcodes these paths)
  system.activationScripts.binCompat = ''
    mkdir -p /bin
    ln -sf ${pkgs.coreutils}/bin/mkdir /bin/mkdir
    ln -sf ${pkgs.coreutils}/bin/ln /bin/ln
  '';

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  hardware.bluetooth.enable = true;

  fileSystems = {
    "/boot/firmware" = {
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
      options = [
        "noatime"
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=1min"
      ];
    };
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };

  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 2 * 1024;
    }
  ];

  zramSwap = {
    enable = true;
    memoryMax = 4 * 1024 * 1024 * 1024;
  };

  system.stateVersion = "25.11";

  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://nixos-raspberrypi.cachix.org"
      "https://cache.garnix.io"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gGypjAp7Ad76rJXldK03C6G6OM="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ username ];
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
        inherit system;
        config.allowUnfree = true;
      };
      masterpkgs = import inputs.nixpkgs-master {
        inherit system;
        config.allowUnfree = true;
      };
    };
    users.${username} = {
      imports = [
        inputs.nix-openclaw.homeManagerModules.openclaw
        ../home
        ./home.nix
      ];
    };
  };
}
