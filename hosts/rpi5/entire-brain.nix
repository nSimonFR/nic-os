# Entire Brain upkeep. Entire's own hooks never call Brain, so an hourly pass
# refreshes nic-os' project memory and distills new sessions: cheap model, one at
# a time, at most 10 a day (the gate persists across runs). A 2-way backfill plus
# Brain's always-on watcher took the Pi (3.9 GB) down on 2026-10-26.
# `entire brain setup` writes that watcher with the store path baked in; the
# copy is removed before linking, or it would block Home Manager.
{ config, lib, ... }:
let
  generated = "entire-brain-watch.service";
  logs = "${config.home.homeDirectory}/.local/state/entire/logs/watch.log";
in
{
  systemd.user.services.entire-brain-refresh = {
    Unit.Description = "Entire Brain refresh + distill";
    Service = {
      Type = "oneshot";
      ExecStart = "/run/current-system/sw/bin/entire-brain workspace watch --once --distill --model haiku --max-sessions 10";
      Environment = [
        # The distill step runs claude; entire's login lives in a file (no keyring).
        "PATH=/run/wrappers/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
        "ENTIRE_PLUGIN_DATA_DIR=${config.home.homeDirectory}/.local/share/entire/plugins/data/brain"
        "ENTIRE_TOKEN_STORE=file"
      ];
      StandardOutput = "append:${logs}";
      StandardError = "append:${logs}";
      Nice = 10;
    };
  };

  systemd.user.timers.entire-brain-refresh = {
    Unit.Description = "Hourly Entire Brain refresh";
    Timer = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "10m";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  home.activation.entireBrainGeneratedUnit = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    d=$HOME/.config/systemd/user
    if [ -f "$d/${generated}" ] && [ ! -L "$d/${generated}" ]; then
      rm -f "$d/${generated}" "$d/default.target.wants/${generated}"
    fi
  '';
}
