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

}
