# Cachix Deploy agent — activates the system that .github/workflows/deploy-rpi5.yml
# built and pushed to nsimon-nicos. The Pi never evaluates the config itself:
# that eval peaks at ~2.1 GiB RSS and earlyoom SIGTERMs it (2026-10-01).
#
# Nothing is stopped around a deploy: activation restarts only changed units.
# The substitution runs in nix-daemon, which configuration.nix schedules idle and
# psi-oom freezes during a memory stall.
{ pkgs, inputs, ... }:
{
  services.cachix-agent = {
    enable = true;
    package = inputs.cachix.packages.${pkgs.stdenv.hostPlatform.system}.cachix; # see flake.nix
    credentialsFile = "/run/agenix/cachix-agent-token";
  };

  # psi-oom spares adj < 0. On 2026-11-22 it killed the agent's `nix-store -r`
  # (130 MiB) during a memory stall, and every nixpkgs-bump deploy died with
  # "Failed to run nix-store -9". The client is small; the stall's real weight
  # is in nix-daemon (frozen by psi-oom) and the services it kills instead.
  systemd.services.cachix-agent.serviceConfig.OOMScoreAdjust = -500;
}
