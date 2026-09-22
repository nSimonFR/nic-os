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

  # Homebrew 5.x's `brew bundle` invokes `mas get <id>` to install Mac App Store
  # apps, but nixpkgs release-25.11 still ships mas 2.2.2 (pre-`get`). Pull mas
  # from nixpkgs-unstable (6.0.1+) so masApps entries can actually install.
  nixpkgs.overlays = [
    (final: prev: {
      mas = (import inputs.nixpkgs-unstable {
        inherit (prev.stdenv.hostPlatform) system;
        config.allowUnfree = true;
      }).mas;
    })
  ];

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
    # RPi5 blocky over the tailnet; Cloudflare is the one fallback, in cleartext.
    # It has to stay: macOS falls through on timeout, and tailscaled's own
    # bootstrap DNS has been seen failing every hardcoded DERP IP during a link
    # switch, so a tailnet-only resolver wedges DNS until someone intervenes.
    dns = [
      "100.122.54.2"   # RPi5 – Tailscale
      "1.0.0.1"        # Cloudflare – fallback, breaks the tailscale/DNS cycle.
                       # Not 1.1.1.1: blackholed on some networks (iciwifi drops
                       # it on UDP, TCP and ICMP alike), so it stalls 2s and dies.
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

  # Work Tailscale: runs alongside the macOS app (personal) in userspace mode
  # tun2proxy creates a TUN interface that transparently routes work subnets
  # through the SOCKS5 proxy, so MCP clients and other apps need no proxy config
  launchd.daemons."tailscale-work" = {
    serviceConfig = {
      ProgramArguments = [
        "/opt/homebrew/opt/tailscale/bin/tailscaled"
        "--tun=userspace-networking"
        "--socks5-server=localhost:1055"
        "--outbound-http-proxy-listen=localhost:1056"
        "--statedir=/var/lib/tailscale-work"
        "--socket=/var/run/tailscale-work/tailscaled.sock"
        "--port=41642"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardErrorPath = "/var/log/tailscale-work.log";
      StandardOutPath = "/var/log/tailscale-work.log";
    };
  };

  # tun2proxy: starts TUN, sets up routes and /etc/hosts from work tailscaled
  # Manual refresh: sudo launchctl kickstart -k system/org.nixos.tun2proxy-work
  launchd.daemons."tun2proxy-work" = {
    serviceConfig = {
      ProgramArguments = [ "/bin/bash" "${./scripts/tun2proxy-work.sh}" ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardErrorPath = "/var/log/tun2proxy-work.log";
      StandardOutPath = "/var/log/tun2proxy-work.log";
    };
  };

  # Daily restart of tun2proxy to re-discover peers/subnets
  launchd.daemons."tun2proxy-work-refresh" = {
    serviceConfig = {
      ProgramArguments = [ "/bin/launchctl" "kickstart" "-k" "system/org.nixos.tun2proxy-work" ];
      StartCalendarInterval = [{ Hour = 6; Minute = 0; }];
    };
  };

  # DNS resolver for cluster.local -> work K8s CoreDNS (routed via tun2proxy)
  environment.etc."resolver/cluster.local".text = "nameserver 192.168.64.10\n";

  system = import ./components/system.nix { inherit pkgs username; };
  homebrew = import ./components/homebrew.nix { inherit pkgs; };
  services.yabai = import ./components/yabai.nix { inherit pkgs inputs; };

  # Homebrew 6 refuses to load formulae/casks from non-official taps unless they
  # are trusted (HOMEBREW_REQUIRE_TAP_TRUST). We deliberately use several third-party
  # taps (dbt-labs, jorgelbg, jundot, rhettbull, auth0, sikarugir, …), so the
  # `darwin-rebuild` `brew bundle` step fails on them. Disable the requirement
  # system-wide via Homebrew's env file — read from /etc (which is set up before the
  # bundle runs) on every brew invocation, independent of HOME/XDG.
  environment.etc."homebrew/brew.env".text = "HOMEBREW_NO_REQUIRE_TAP_TRUST=1\n";

}
