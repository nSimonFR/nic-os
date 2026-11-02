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
  imports = [
    ./components/homebrew.nix
    ./cachix-agent.nix
    ./entire.nix
    ./home-manager-activation.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # Homebrew 5.x's `brew bundle` invokes `mas get <id>` to install Mac App Store
  # apps, but nixpkgs release-25.11 still ships mas 2.2.2 (pre-`get`). Pull mas
  # from nixpkgs-unstable (6.0.1+) so masApps entries can actually install.
  nixpkgs.overlays = [
    (_final: prev: {
      inherit
        (
          (import inputs.nixpkgs-unstable {
            inherit (prev.stdenv.hostPlatform) system;
            config.allowUnfree = true;
          })
        )
        mas
        ;
    })
  ];

  #nix.configureBuildUsers = true;

  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  # 461 GB disk shared with everything else; GC freed 8.6 GB on 2026-10-28 at 4 GB free.
  nix.gc = {
    automatic = true;
    interval = [
      {
        Weekday = 0;
        Hour = 12;
        Minute = 0;
      }
    ];
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

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
      "100.122.54.2" # RPi5 – Tailscale
      "1.1.1.1" # Cloudflare – fallback
      "9.9.9.9" # Quad9 – fallback
    ];
  };

  programs.zsh.enable = true;

  users.users.${username}.home = "/Users/${username}";

  environment.systemPackages = [
    pkgs.gcc
    pkgs.gnupg
  ];

  security.pam.services.sudo_local.touchIdAuth = true;
  # pam_reattach: without it pam_tid falls back to a password inside herdr/tmux.
  security.pam.services.sudo_local.reattach = true;

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

  # Work tailnet via tailmux (TUN mode), alongside the macOS app (personal tailnet).
  # It writes /etc/resolver files for the tailnet's names and split-DNS domains
  # and routes its peers and subnets into its own utun, so apps need no proxy.
  # Status: `tailmux status`; re-apply routes and DNS: `tailmux repair`.
  # State (node key): /opt/homebrew/var/lib/tailmux/<state>.
  # Settings or an exit node changed from the menu bar or `tailmux exit-node`
  # are written back to this file, replacing nix's symlink and failing the next
  # activation: change them here instead.
  environment.etc."tailmux/config.json".text = builtins.toJSON {
    hostname = "nbookpro";
    # Same ports as the old tailscaled, for anything still set to use a proxy.
    socks5 = "127.0.0.1:1055";
    http = "127.0.0.1:1056";
    direct = true;
    tailnets = [
      # Listed first: bare hostnames (`ssh rpi5`) try tailnets in this order.
      {
        name = "personal";
        # Explicit: tailmux writes a missing `state` back into the config at start.
        state = "personal";
        # Kept from the old Tailscale-app node: rpi5 reaches this Mac by this
        # name and by its IP (100.78.185.89, pinned in the admin console).
        hostname = "macbook-pro-appleosx-15";
        # tailmux nodes only accept what is forwarded here (TCP and HTTP(S); no
        # UDP, so no mosh, and no Funnel).
        serve = [
          {
            port = 22;
            tcp = "22";
          } # ssh, pbpaste from rpi5
          {
            port = 8787;
            tcp = "8787";
          } # linear-t3-relay nsimon, via rpi5's path-mux
          {
            port = 8788;
            tcp = "8788";
          } # linear-t3-relay work
          {
            port = 8443;
            https = "8000";
          } # rpi5 tiny-llm-gate
          {
            port = 8910;
            https = "3773";
          } # T3 Code
        ];
      }
      {
        name = "work";
        state = "work";
      }
    ];
    tun.enabled = true;
    # Upgrades go through `brew upgrade`, not a root daemon pulling releases.
    updates.auto = false;
  };
  launchd.daemons."tailmux" = {
    serviceConfig = {
      ProgramArguments = [
        "/opt/homebrew/opt/tailmux/bin/tailmux"
        "up"
        "-config"
        "/etc/tailmux/config.json"
      ];
      # tailmux reads its config at start only; a new hash changes the plist,
      # so activation reloads the daemon.
      EnvironmentVariables.TAILMUX_CONFIG_SHA256 =
        builtins.hashString "sha256"
          config.environment.etc."tailmux/config.json".text;
      RunAtLoad = true;
      KeepAlive = true;
      StandardErrorPath = "/var/log/tailmux.log";
      StandardOutPath = "/var/log/tailmux.log";
    };
  };

  # cluster.local -> work K8s CoreDNS, reached through a tailmux subnet route
  environment.etc."resolver/cluster.local".text = "nameserver 192.168.64.10\n";

  system = import ./components/system.nix { inherit pkgs username; };
  services.yabai = import ./components/yabai.nix { inherit pkgs inputs; };

  # Homebrew 6 refuses to load formulae/casks from non-official taps unless they
  # are trusted (HOMEBREW_REQUIRE_TAP_TRUST). We deliberately use several third-party
  # taps (dbt-labs, jorgelbg, jundot, rhettbull, auth0, sikarugir, …), so the
  # `darwin-rebuild` `brew bundle` step fails on them. Disable the requirement
  # system-wide via Homebrew's env file — read from /etc (which is set up before the
  # bundle runs) on every brew invocation, independent of HOME/XDG.
  environment.etc."homebrew/brew.env".text = "HOMEBREW_NO_REQUIRE_TAP_TRUST=1\n";

}
