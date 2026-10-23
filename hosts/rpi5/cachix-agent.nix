# Cachix Deploy agent — activates the system that .github/workflows/deploy-rpi5.yml
# built and pushed to nsimon-nicos. The Pi never evaluates the config itself:
# that eval peaks at ~2.1 GiB RSS and earlyoom SIGTERMs it (2026-10-01).
{ config, pkgs, ... }:
let
  cfg = config.services.cachix-agent;

  # The agent execs `<getBinDir>/.cachix-deployment` per deploy, and Cabal's
  # getBinDir honours $cachix_bindir. Point it here so the download + switch
  # runs under heavy-shed: at full idle load the 1887-path 26.05 deploy hit the
  # 30s watchdog three times (2026-10-23).
  deployment = pkgs.writeShellApplication {
    name = "cachix-deployment-shed";
    runtimeInputs = [ config.nic.heavyShed ];
    text = ''
      HEAVY_SHED_RESTORE=always exec heavy-shed ${cfg.package}/bin/.cachix-deployment "$@"
    '';
  };
  bindir = pkgs.runCommand "cachix-deployment-bindir" { } ''
    mkdir -p $out/bin
    ln -s ${deployment}/bin/cachix-deployment-shed $out/bin/.cachix-deployment
  '';
in
{
  services.cachix-agent = {
    enable = true;
    credentialsFile = "/run/agenix/cachix-agent-token";
  };

  systemd.services.cachix-agent.environment.cachix_bindir = "${bindir}/bin";
}
