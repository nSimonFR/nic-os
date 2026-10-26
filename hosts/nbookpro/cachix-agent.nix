# Cachix Deploy agent — activates the system that .github/workflows/deploy-nbookpro.yml
# built and pushed to nsimon-nicos.
#
# Token: one-time, by hand — `export CACHIX_AGENT_TOKEN=…` in /etc/cachix-agent.token
# (root, 0600). The daemon watches that path and starts once it exists.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.cachix-agent;
in
{
  services.cachix-agent.enable = true;
  services.cachix-agent.package = inputs.cachix.packages.${pkgs.stdenv.hostPlatform.system}.cachix; # see flake.nix

  # The agent defaults to system-profiles/system on macOS; darwin-rebuild (rebuild-os)
  # uses /nix/var/nix/profiles/system. Same profile keeps one generation list.
  # A missing or empty token would restart-loop every 10s (KeepAlive); back off instead.
  launchd.daemons.cachix-agent.script = lib.mkForce ''
    if ! grep -qs CACHIX_AGENT_TOKEN= ${cfg.credentialsFile}; then
      echo "no CACHIX_AGENT_TOKEN in ${cfg.credentialsFile}" >&2
      sleep 300
      exit 1
    fi
    # set -a: a line without `export` still reaches cachix.
    set -a
    . ${cfg.credentialsFile}
    set +a

    exec ${cfg.package}/bin/cachix deploy agent ${cfg.name} system
  '';
}
