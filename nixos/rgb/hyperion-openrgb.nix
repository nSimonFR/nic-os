{ pkgs, ... }:

let
  hyperion-ng-openrgb = pkgs.callPackage ../../pkgs/rgb/hyperion-ng-openrgb.nix { };
in
{
  environment.systemPackages = [ hyperion-ng-openrgb ];

  # Hyperion systemd service
  systemd.user.services.hyperion = {
    description = "Hyperion Ambient Light System";
    after = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${hyperion-ng-openrgb}/bin/hyperiond";
      Restart = "on-failure";
      RestartSec = "5s";
    };

    # Disabled - using OpenRGB effects instead
    # wantedBy = [ "default.target" ];
  };

  # Open firewall for Hyperion web interface
  networking.firewall.allowedTCPPorts = [
    8090
    19444
    19445
  ];
}
