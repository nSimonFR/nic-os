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
}
