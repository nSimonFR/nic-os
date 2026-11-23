# Beszel agent for the Mac, reporting to the rpi5 hub (hosts/rpi5/platform/monitoring.nix).
# It dials the hub over WebSocket, so the macOS firewall and a sleeping or roaming
# Mac need no inbound port. TOKEN matches the nBookPro system's fingerprint record.
{
  config,
  lib,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  home = config.home.homeDirectory;
  stateDir = "${home}/Library/Application Support/beszel-agent";
  logs = "${home}/Library/Logs/beszel-agent.log";
  identity = builtins.head config.age.identityPaths;
  tokenFile = ../../shared/beszel-agent-nbookpro.env.age;

  run = pkgs.writeShellApplication {
    name = "beszel-agent-run";
    runtimeInputs = [ pkgs.age ];
    text = ''
      umask 077
      mkdir -p "${stateDir}"
      env=$(age -d -i "${identity}" ${tokenFile})
      set -a
      eval "$env"
      set +a
      export DATA_DIR="${stateDir}"
      export HUB_URL="https://${tailnetFqdn}:3000"
      # The hub's public key (GET /api/beszel/getkey): the agent only trusts its signature.
      export KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnrMibplBybzPfg/TmufH8HOXLDK36erbUh2XvSq6Ku"
      exec ${pkgs.beszel}/bin/beszel-agent
    '';
  };
in
{
  launchd.agents.beszel-agent = {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe run) ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30; # retry pace while off the tailnet
      ProcessType = "Background";
      StandardOutPath = logs;
      StandardErrorPath = logs;
    };
  };
}
