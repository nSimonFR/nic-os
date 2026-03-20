{
  config,
  lib,
  pkgs,
  inputs,
  outputs,
  username,
  nixos-raspberrypi,
  ...
}:
let
  blogwatcherPkg = pkgs.callPackage ./blogwatcher.nix { };

  # Fix nixos-raspberrypi bug: kernelboot-gen-builder.sh writes default/cmdline.txt
  # with a hardcoded nix store path instead of a profile symlink, causing boot failure
  # after nix GC deletes the store path (weekly GC).
  #
  # Root cause: the "default" entry receives $generationPath as the raw store path
  # (e.g. /nix/store/…-nixos-system-rpi5-…), while numbered entries receive the
  # stable profile symlink (/nix/var/nix/profiles/system-N-link). We rebuild the
  # full bootloader chain from nixos-raspberrypi source with a patched
  # kernelboot-gen-builder.sh that uses /nix/var/nix/profiles/system/init for the
  # "default" entry instead of the GC-able store path.
  rpiBootSrc = "${nixos-raspberrypi}/modules/system/boot/loader/raspberrypi/generational";
  rpiCfg = config.boot.loader.raspberry-pi;

  # Python patch: replace the init= line in addEntry() with a symlink-stable version
  patchScript = pkgs.writeText "patch-kernelboot.py" ''
    import sys
    src = open(sys.argv[1]).read()
    old = '    echo "$(cat "$generationPath/kernel-params") init=$generationPath/init" > "$genDir/cmdline.txt"'
    new = (
        '    local initPath="$generationPath/init"\n'
        '    if [ "$generationName" = "default" ]; then\n'
        '        initPath="/nix/var/nix/profiles/system/init"\n'
        '    fi\n'
        '    echo "$(cat "$generationPath/kernel-params") init=$initPath" > "$genDir/cmdline.txt"'
    )
    assert old in src, "Patch target not found in kernelboot-gen-builder.sh"
    open(sys.argv[1], "w").write(src.replace(old, new))
  '';

  patchedKernelbootGenBuilderSrc = pkgs.runCommand "kernelboot-gen-builder-patched.sh" { } ''
    cp ${rpiBootSrc}/kernelboot-gen-builder.sh $out
    chmod +w $out
    ${pkgs.python3}/bin/python3 ${patchScript} $out
  '';

  deviceTreeInstaller = pkgs.replaceVarsWith {
    src = "${rpiBootSrc}/install-device-tree.sh";
    isExecutable = true;
    replacements = {
      inherit (pkgs) bash;
      path = pkgs.lib.makeBinPath [ pkgs.coreutils ];
      firmware = rpiCfg.firmwarePackage;
    };
  };

  kernelbootGenBuilder = pkgs.replaceVarsWith {
    src = patchedKernelbootGenBuilderSrc;
    isExecutable = true;
    replacements = {
      inherit (pkgs) bash;
      path = pkgs.lib.makeBinPath [ pkgs.coreutils ];
      installDeviceTree =
        let args = lib.optionalString (!rpiCfg.useGenerationDeviceTree) " -r";
        in "${deviceTreeInstaller}${args}";
    };
  };

  firmwareInstaller = pkgs.replaceVarsWith {
    src = "${rpiBootSrc}/install-firmware.sh";
    isExecutable = true;
    replacements = {
      inherit (pkgs) bash;
      path = pkgs.lib.makeBinPath [ pkgs.coreutils ];
      firmware = rpiCfg.firmwarePackage;
      configTxt = rpiCfg.configTxtPackage;
    };
  };

  patchedBootloader = pkgs.replaceVarsWith {
    src = "${rpiBootSrc}/nixos-generations-builder.sh";
    isExecutable = true;
    replacements = {
      inherit (pkgs) bash;
      path = pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gnused ];
      installFirmwareBuilder = firmwareInstaller;
      nixosGenerationsDir = rpiCfg.nixosGenerationsDir;
      nixosGenBuilder = kernelbootGenBuilder;
    };
  };
in
{
  # Override the bootloader installer (nixos-raspberrypi sets mkOverride 60;
  # mkForce = priority 50 wins) with the patched version built above.
  system.build.installBootLoader = lib.mkForce (
    "${patchedBootloader} -g ${toString rpiCfg.configurationLimit} -f ${rpiCfg.firmwarePath} -c"
  );

  # Workaround for nixpkgs 25.11 rename.nix <-> nixos-raspberrypi conflict
  disabledModules = [ "rename.nix" ];

  imports = with nixos-raspberrypi.nixosModules; [
    (lib.mkAliasOptionModule [ "environment" "checkConfigurationOptions" ] [ "_module" "check" ])
    raspberry-pi-5.base
    raspberry-pi-5.page-size-16k
    raspberry-pi-5.bluetooth
    ./secrets.nix
    ./home-assistant.nix
    ./firefly-iii.nix
    ./blocky.nix
    ./ghostfolio.nix
    # Tailscale with server features (subnet routing, SSH, exit node)
    (import ../shared/tailscale.nix {
      role = "server";
      enableSSH = true;
      advertiseExitNode = true;
    })
  ];

  nixpkgs.config.allowUnfree = true;

  boot.loader.raspberry-pi.bootloader = "kernel";

  # Force USB mass storage mode for Realtek RTL9210 NVMe-over-USB adapter.
  # Without this quirk the kernel uses UAS which breaks enumeration on RPi5.
  boot.kernelParams = [ "usb-storage.quirks=0bda:9210:u" ];

  # Headless server — blacklist vc4 GPU driver to prevent silent CPU stall
  # when accessing uninitialized HDMI registers (firmware doesn't init HSM clock
  # without a monitor connected, causing vc4_hdmi_runtime_resume to hang).
  boot.blacklistedKernelModules = [ "vc4" ];

  networking = {
    hostName = "rpi5";
    useNetworkd = true;
    wireless.iwd = {
      enable = false;
    };
  };

  services.resolved.enable = true;

  time.timeZone = "Europe/Paris";

  i18n.defaultLocale = "en_US.UTF-8";

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  users.users.${username} = {
    isNormalUser = true;
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
    enable = false;
    flake = "github:nSimonFR/nic-os#rpi5";
    # Required because flake outputs reference a local path source for OpenClaw skills.
    flags = [ "--impure" ];
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
    ethtool
    wakeonlan
    sqlite  # SQL database for structured data storage
    blogwatcherPkg
    hydroxide
  ];

  virtualisation.docker.enable = true;

  # ── Ghostfolio: Wealth management software ──────────────────────────
  # Temporarily disabled: npmDepsHash needs update (build fails with cache error)
  services.ghostfolio.enable = false;

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
      device = "/dev/disk/by-label/NIXOS_SSD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    # NVMe RAID-1 array for /home (Docker data at /home/state/var-lib/docker)
    "/home" = {
      device = "/dev/disk/by-label/HOME_RAID";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    # Bind /home/state/var-lib → /var/lib for Docker state
    # neededForBoot = false: prevent NixOS from auto-adding x-initrd.mount.
    # /home (RAID-1) is only available in stage-2, so this bind must be stage-2 only.
    "/var/lib" = {
      device = "/home/state/var-lib";
      fsType = "none";
      options = [ "bind" "nofail" ];
      neededForBoot = false;
    };
  };

  swapDevices = [
    {
      # Swapfile on root (NIXOS_SD) — avoids ordering dependency on /home mount
      device = "/swapfile";
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
      "cache.nixos.org-1:6NCHdD59X431o0gWQnrDg8a8NLFkBE/eCiST04Xhd00="
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
    options = "--delete-older-than 7d";
  };

  # Tailscale Serve: declarative service proxies (easily extensible)
  # To add a new service, append to serveServices list: { port = XXXX; name = "name"; localPort = YYYY; }
  systemd.services.tailscale-serve =
    let
      serveServices = [
        { port = 443; name = "openclaw"; localPort = 18789; }
        { port = 3333; name = "ghostfolio"; localPort = 3333; }
      ];
      
      serveCommands = lib.concatMapStringsSep "\n    " (service:
        "# ${service.name}: https://rpi5:${toString service.port}"
        + "\n    ${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString service.port} http://127.0.0.1:${toString service.localPort}"
      ) serveServices;
      
      serveStopCommands = lib.concatMapStringsSep "\n      " (service:
        "${pkgs.tailscale}/bin/tailscale serve --https=${toString service.port} off || true"
      ) serveServices;
    in
    {
      description = "Tailscale Serve HTTPS proxies for local services (tailnet-only)";
      after = [ "network-online.target" "tailscaled.service" "tailscale-autoconnect.service" ];
      wants = [ "network-online.target" "tailscaled.service" "tailscale-autoconnect.service" ];
      requires = [ "tailscale-autoconnect.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "15s";
      };
      script = ''
        sleep 2
        # Reset all Tailscale Serve routes to ensure clean state
        ${pkgs.tailscale}/bin/tailscale serve reset || true
        # Now configure all routes atomically
        ${serveCommands}
      '';
      preStop = ''
        ${serveStopCommands}
      '';
    };

}
