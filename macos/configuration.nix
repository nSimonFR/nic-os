{
  config,
  pkgs,
  inputs,
  outputs,
  username,
  hostname,
  lib,
  ...
}:
{
  nixpkgs.config.allowUnfree = true;

  #nix.configureBuildUsers = true;

  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  networking = {
    hostName = hostname;
    localHostName = hostname;
    knownNetworkServices = [
      "USB 10/100/1000 LAN"
      "Thunderbolt Bridge"
      "Wi-Fi"
      "iPhone USB"
      "ProtonVPN"
      "Urban VPN Desktop"
    ];
    # Use RPi5 blocky for DNS (ad/tracker/malware blocking)
    # Tailscale IP first (works everywhere), LAN second (home network),
    # Cloudflare/Quad9 last resort if RPi5 is unreachable
    dns = [
      "192.168.1.100"  # RPi5 – LAN (home network only)
      "100.122.54.2"   # RPi5 – Tailscale
      "1.1.1.1"        # Cloudflare – fallback
      "9.9.9.9"        # Quad9 – fallback
    ];
  };

  programs.zsh.enable = true;

  users.users.${username}.home = "/Users/${username}";

  environment.systemPackages = [ pkgs.gcc pkgs.gnupg ];

  security.pam.services.sudo_local.touchIdAuth = true;

  services.skhd = {
    enable = true;
    skhdConfig = builtins.readFile ./dotfiles/skhdrc;
  };

  launchd.daemons."start-programs".serviceConfig = {
    ProgramArguments = [
      "open"
      "/Applications/Vanilla.app/"
    ];
    RunAtLoad = true;
    StandardErrorPath = "/var/log/start-programs.log";
    StandardOutPath = "/var/log/start-programs.log";
  };

  system = import ./components/system.nix { inherit pkgs username; };
  homebrew = import ./components/homebrew.nix { inherit pkgs; };
  services.yabai = import ./components/yabai.nix { inherit pkgs; };

  services.tailscale = {
    enable = true;
    # macOS doesn't support all Linux Tailscale options via nix-darwin
    # Tailscale automatically handles NAT traversal on macOS
    # 
    # Manual setup via CLI:
    # tailscale up --accept-routes --accept-dns
  };

  # Home Manager — integrated so darwin-rebuild deploys user config too
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs outputs username;
      devSetup = true;
      unstablepkgs = import inputs.nixpkgs-unstable {
        system = "aarch64-darwin";
        config.allowUnfree = true;
      };
      masterpkgs = import inputs.nixpkgs-master {
        system = "aarch64-darwin";
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
