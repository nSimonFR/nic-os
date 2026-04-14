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
    ./databases.nix
    ./home-assistant.nix
    ./tailscale-serve.nix
    ./blocky.nix
    ./scrutiny.nix
    ./monitoring
    ./filebrowser.nix
    ./openai-codex-proxy.nix
    ./immich.nix
    ./sure.nix
    ./sumeria-mitm.nix
    ./llm-interceptor.nix
    ./vaultwarden.nix
    ./affine.nix
    ./backups.nix
    ./storj-backup.nix
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
  # usbcore.autosuspend=-1: disable USB autosuspend globally to prevent the
  # RTL9210 root disk from entering suspend and hanging on resume (which causes
  # catastrophic IO wait / system freeze).
  boot.kernelParams = [
    "usb-storage.quirks=0bda:9210:u"
    "usbcore.autosuspend=-1"
  ];

  # Hardware watchdog: if the system freezes (e.g. IO wait from USB disk hang),
  # the BCM2835 watchdog will reboot automatically after 30s of silence.
  systemd.watchdog.runtimeTime = "30s";

  # ── VM / memory pressure tuning ────────────────────────────────────────────
  # RPi5 has 4 GiB RAM and runs many services; these settings prevent hang-
  # inducing swap storms:
  # - swappiness 150: prefer zram (in-RAM compressed swap, near-zero I/O cost)
  #   over evicting hot page cache. Values >100 are valid on kernel ≥5.8.
  # - overcommit_memory 0: heuristic limit (≈ RAM + swap × ratio) instead of
  #   unconditional "yes", so allocations that can never be satisfied are
  #   refused early rather than causing a late-stage OOM hang.
  # - watermark_scale_factor 50: wake kswapd at ≈0.5% free (≈20 MiB) vs the
  #   default 0.1% (≈4 MiB), giving the reclaimer more runway before the
  #   system stalls waiting for free pages.
  # - vfs_cache_pressure 50: retain dentries/inodes longer under pressure,
  #   reducing metadata I/O on the SD card.
  boot.kernel.sysctl = {
    "vm.swappiness"             = 150;
    # Redis NixOS module also sets this to "1"; mkForce overrides it.
    # overcommit=0 (heuristic) is safe for our small Redis instances.
    "vm.overcommit_memory"      = lib.mkForce 0;
    "vm.watermark_scale_factor" = 50;
    "vm.vfs_cache_pressure"     = 50;
  };

  # ── OOM management ────────────────────────────────────────────────────────
  # systemd-oomd requires PSI (pressure stall info) which needs memory cgroup
  # accounting — disabled by RPi5 firmware (cgroup_disable=memory injected via
  # /chosen/bootargs). Use earlyoom instead: it only needs /proc/meminfo and
  # proactively sends SIGTERM to the highest-RSS process before free memory
  # hits zero and the system freezes waiting for the hardware watchdog.
  services.earlyoom = {
    enable = true;
    # SIGTERM at <4% free RAM (~160 MiB) or <5% free swap (~250 MiB).
    # SIGKILL follows at <2% / <3% if SIGTERM doesn't free enough in time.
    freeMemThreshold      = 4;
    freeMemKillThreshold  = 2;
    freeSwapThreshold     = 5;
    freeSwapKillThreshold = 3;
    extraArgs = [
      # Prefer expendable heavy processes: immich transcoding/API and ffmpeg.
      "--prefer" "(immich|ffmpeg)"
      # Protect critical infrastructure from being the first killed.
      "--avoid"  "(postgres|redis-server|blocky|nginx|tailscaled|sshd|journald)"
    ];
  };

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

  services.llm-interceptor.enable = true;

  # Cap journal size to reduce RSS and disk usage on 4 GB RPi5
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    RuntimeMaxUse=20M
  '';

  time.timeZone = "Europe/Paris";

  i18n.defaultLocale = "en_US.UTF-8";

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  users.users.root.hashedPassword = "$6$2l0dzdBCwOb5a4c7$zKxnFzxOblPypU4F5c2PYMETNxedNyqvTA8u2KOpmpJ9Iwtw7B0.UMZFL7LNDlExhyjSbGWKQnEIn8ja2ZfTi.";

  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "video"
      "networkmanager"
    ];
    home = "/home/${username}";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIoO5ICofBCfox+M2Uz91qBRF794BwHhQJBL/9dSZahr nsimon@rpi5-openclaw"
    ];
  };

  # Fallback for SSH sessions where pam_systemd doesn't propagate XDG_RUNTIME_DIR
  # (non-PTY SSH, Tailscale SSH, etc.). Required for agenix secrets at $XDG_RUNTIME_DIR/agenix/.
  environment.extraInit = ''
    if [ -z "$XDG_RUNTIME_DIR" ]; then
      export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
  '';

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
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
    immich-cli
    dnsutils  # dig, nslookup
    smartmontools
  ];


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

  hardware.bluetooth.enable = lib.mkForce false;

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
    "/home" = {
      device = "/dev/disk/by-label/HOME_SSD";
      fsType = "ext4";
      options = [ "noatime" "nofail" ];
    };
    "/mnt/data" = {
      device = "/dev/disk/by-label/DATA_HDD";
      fsType = "ext4";
      options = [ "noatime" "nofail" ];
    };
  };



  zramSwap = {
    enable = true;
    memoryPercent = 200; # 200% of 4 GiB ≈ 8 GiB virtual; actual RAM bounded by zstd compression (~3-4x)
    memoryMax = 10 * 1024 * 1024 * 1024;
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

  # Tailscale Serve + Funnel are now managed declaratively via TS_SERVE_CONFIG.
  # See tailscale-serve.nix.

}
