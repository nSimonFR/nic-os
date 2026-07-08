{ pkgs, unstablePkgs, lib, config, ... }:
{
  # unstable ships wakatime-cli 2.15.0; stable (25.11) still pins 1.130.1 which
  # predates the [api_urls] config section. We need >=2.x so ~/.wakatime.cfg's
  # [api_urls] fan-out (tee heartbeats to self-hosted wakapi alongside
  # wakatime.com) is honoured. Editor-embedded wakatime clients already run 2.x.
  home.packages = [ unstablePkgs.wakatime-cli ];

  # ~/.wakatime.cfg — written from agenix-managed encrypted INI.
  # Plugins (Cursor, VS Code, Zed, Vim, browser ext, Claude Code hook) all
  # read this file. Editor-specific wiring lives in ./editors.nix.
  home.activation.wakatimeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -f "${config.age.secrets.wakatime-cfg.path}" ]; then
      run install -m 600 "${config.age.secrets.wakatime-cfg.path}" "$HOME/.wakatime.cfg"
    fi
  '';
}
