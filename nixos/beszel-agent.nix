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
    serviceConfig = {
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      DynamicUser = true;
      EnvironmentFile = "/etc/beszel/agent.env";
      Restart = "on-failure";
      RestartSec = "10s";
      ConditionPathExists = "/etc/beszel/agent.env";
      Environment = [
        "PORT=${toString beszelAgentPort}"
        "FILESYSTEM=/dev/nvme0n1p2,/dev/nvme1n1p3,/dev/sda2,/dev/sdc2"
      ];
      ProtectProc = "default";
    };
  };
}
