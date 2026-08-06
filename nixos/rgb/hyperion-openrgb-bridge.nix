{ pkgs, ... }:

let
  hyperion-openrgb-bridge = pkgs.callPackage ../../pkgs/rgb/hyperion-openrgb-bridge.nix { };
in
{
  environment.systemPackages = [ hyperion-openrgb-bridge ];

  # Systemd service for the bridge
  systemd.user.services.hyperion-openrgb-bridge = {
    description = "Hyperion to OpenRGB Bridge";
    after = [ "hyperion.service" ];
    requires = [ "hyperion.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${hyperion-openrgb-bridge}/bin/hyperion-openrgb-bridge";
      Restart = "on-failure";
      RestartSec = "5s";
    };

    # Disabled - using OpenRGB effects instead
    # wantedBy = [ "default.target" ];
  };

  # Open firewall for bridge UDP port
  networking.firewall.allowedUDPPorts = [ 19446 ];
}
