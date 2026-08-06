{ pkgs, ... }:
let
  beszelAgentPort = 45876;
in
{
  systemd.services.beszel-agent = {
    description = "Beszel monitoring agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.smartmontools ];
    # Condition* directives are [Unit] directives. Setting this under
    # `serviceConfig` put it in [Service], where systemd ignores it (it warns and
    # carries on), so the unit started with no env file, failed on the missing
    # EnvironmentFile, and restart-looped instead of staying inactive. The rpi5's
    # copy of this module has always had it right — see hosts/rpi5/monitoring.nix.
    unitConfig.ConditionPathExists = "/etc/beszel/agent.env";
    serviceConfig = {
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      DynamicUser = true;
      EnvironmentFile = "/etc/beszel/agent.env";
      Restart = "on-failure";
      RestartSec = "10s";
      Environment = [
        "PORT=${toString beszelAgentPort}"
        "FILESYSTEM=/dev/nvme0n1p2,/dev/nvme1n1p3,/dev/sda2,/dev/sdc2"
        "SMART_INTERVAL=1h"
      ];
      ProtectProc = "default";
      AmbientCapabilities    = [ "CAP_SYS_RAWIO" "CAP_SYS_ADMIN" ];
      CapabilityBoundingSet  = [ "CAP_SYS_RAWIO" "CAP_SYS_ADMIN" ];
      DeviceAllow            = [
        "/dev/nvme0n1 r"
        "/dev/nvme1n1 r"
        "/dev/sda r"
        "/dev/sdb r"
        "/dev/sdc r"
      ];
      SupplementaryGroups    = [ "disk" ];
    };
  };
}
