# Entire Brain's watcher: keeps nic-os' project memory fresh and distills new
# sessions (cheap model, at most once a day). `entire brain setup` writes this
# unit itself, with the current store path and a snapshot of $PATH baked in, so
# it would break on the next upgrade or GC. Declared here instead; the generated
# copy is removed before linking, or it would block Home Manager.
{ config, lib, ... }:
let
  unit = "entire-brain-watch.service";
  logs = "${config.home.homeDirectory}/.local/state/entire/logs/watch.log";
in
{
  systemd.user.services.entire-brain-watch = {
    Unit = {
      Description = "Entire Brain watcher";
      After = [ "network-online.target" ];
    };
    Install.WantedBy = [ "default.target" ];
    Service = {
      ExecStart = "/run/current-system/sw/bin/entire-brain workspace watch --distill";
      Environment = [
        # The distill step runs claude; entire's login lives in a file (no keyring).
        "PATH=/run/wrappers/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
        "ENTIRE_PLUGIN_DATA_DIR=${config.home.homeDirectory}/.local/share/entire/plugins/data/brain"
        "ENTIRE_TOKEN_STORE=file"
      ];
      StandardOutput = "append:${logs}";
      StandardError = "append:${logs}";
      Restart = "always";
      RestartSec = 60;
      Nice = 10;
    };
  };

  home.activation.entireBrainGeneratedUnit = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    d=$HOME/.config/systemd/user
    if [ -f "$d/${unit}" ] && [ ! -L "$d/${unit}" ]; then
      rm -f "$d/${unit}" "$d/default.target.wants/${unit}"
    fi
  '';
}
