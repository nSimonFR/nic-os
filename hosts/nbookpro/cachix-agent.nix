# Cachix Deploy agent — activates the system that .github/workflows/deploy-nbookpro.yml
# built and pushed to nsimon-nicos.
#
# Token: one-time, by hand — `export CACHIX_AGENT_TOKEN=…` in /etc/cachix-agent.token
# (root, 0600). The daemon watches that path and starts once it exists.
{ config, lib, ... }:
let
  cfg = config.services.cachix-agent;
in
{
  services.cachix-agent.enable = true;

  # The agent defaults to system-profiles/system on macOS; darwin-rebuild (rebuild-os)
  # uses /nix/var/nix/profiles/system. Same profile keeps one generation list.
  # A missing token would restart-loop every 10s (KeepAlive); back off instead.
  launchd.daemons.cachix-agent.script = lib.mkForce ''
    if [ ! -r ${cfg.credentialsFile} ]; then
      echo "missing ${cfg.credentialsFile}" >&2
      sleep 300
      exit 1
    fi
    . ${cfg.credentialsFile}

    exec ${cfg.package}/bin/cachix deploy agent ${cfg.name} system
  '';

  # rebuild-os used to reload the yabai scripting addition after switching; an
  # agent-run switch has no such step, so activation does it.
  system.activationScripts.postActivation.text = lib.mkAfter ''
    ${config.services.yabai.package}/bin/yabai --load-sa \
      || echo "warning: yabai --load-sa failed" >&2
  '';
}
