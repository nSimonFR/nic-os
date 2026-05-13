{ pkgs, lib, config, ... }:
{
  home.packages = [ pkgs.wakatime-cli ];

  home.activation.wakatimeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -f "${config.age.secrets.wakatime-cfg.path}" ]; then
      run install -m 600 "${config.age.secrets.wakatime-cfg.path}" "$HOME/.wakatime.cfg"
    fi
  '';
}
