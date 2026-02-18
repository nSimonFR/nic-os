# Tailscale configuration module
# Supports different roles with sensible defaults
#
# Usage:
#   Import with role parameter:
#     imports = [ (import ../shared/tailscale.nix { role = "client"; }) ];
#     imports = [ (import ../shared/tailscale.nix { role = "server"; enableSSH = true; }) ];
#
# Roles:
#   - "client": Accept routes and DNS (default)
#   - "server": Can advertise routes and serve as subnet router/exit node
#   - "both": Can do both client and server functions

{ 
  role ? "client",
  enableSSH ? false,
  advertiseRoutes ? [],
  advertiseExitNode ? false,
  acceptRoutes ? true,
  acceptDNS ? true,
  extraUpFlags ? []
}:

{ lib, pkgs, ... }:

let
  # Determine routing features based on role
  routingFeatures = {
    client = "client";
    server = "server";
    both = "both";
  }.${role} or "client";
  
  # Build extraUpFlags based on configuration
  upFlags = lib.lists.unique (
    (lib.optionals enableSSH [ "--ssh" ])
    ++ (lib.optionals acceptRoutes [ "--accept-routes" ])
    ++ (lib.optionals acceptDNS [ "--accept-dns" ])
    ++ (lib.optionals (advertiseRoutes != []) [ "--advertise-routes=${lib.concatStringsSep "," advertiseRoutes}" ])
    ++ (lib.optionals advertiseExitNode [ "--advertise-exit-node" ])
    ++ extraUpFlags
  );
  
  # Command to bring up Tailscale with all configured flags
  upCommand = lib.concatStringsSep " " (
    [ "${pkgs.tailscale}/bin/tailscale" "up" ]
    ++ upFlags
    ++ lib.optionals enableSSH [ "--accept-risk=lose-ssh" ]
  );
in
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = routingFeatures;
    extraUpFlags = upFlags;
  };
  
  # Autoconnect service to apply flags on boot
  systemd.services.tailscale-autoconnect = {
    description = "Tailscale autoconnect with configured flags";
    after = [ "network-pre.target" "tailscaled.service" ];
    wants = [ "network-pre.target" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for tailscaled to be ready
      sleep 2
      
      # Bring up Tailscale with configured flags
      ${upCommand}
    '';
  };
  
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    checkReversePath = "loose";
    allowedUDPPorts = [ 41641 ]; # NAT traversal (STUN, hole punching)
  };
  
  # Enable IP forwarding for NAT traversal and routing features
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };
}
