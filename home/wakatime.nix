{ pkgs, lib, config, ... }:
{
  home.packages = [ pkgs.wakatime-cli ];

  # ~/.wakatime.cfg — written from agenix-managed encrypted INI.
  # Plugins (Cursor, VS Code, Zed, Vim, browser ext, Claude Code hook) all
  # read this file. Editor-specific wiring lives in ./editors.nix.
  home.activation.wakatimeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -f "${config.age.secrets.wakatime-cfg.path}" ]; then
      run install -m 600 "${config.age.secrets.wakatime-cfg.path}" "$HOME/.wakatime.cfg"
    fi
  '';
}
