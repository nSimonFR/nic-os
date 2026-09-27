{ pkgs, unstablePkgs, lib, config, ... }:
{
  # unstable ships wakatime-cli 2.x (2.26.0 as of 2026-09); stable (25.11) still pins 1.130.1 which
  # predates the [api_urls] config section. We need >=2.x so ~/.wakatime.cfg's
  # [api_urls] fan-out (tee heartbeats to self-hosted wakapi alongside
  # wakatime.com) is honoured. Editor-embedded wakatime clients already run 2.x.
  home.packages = [ unstablePkgs.wakatime-cli ];

  # AI transcript sync (Claude, Codex, Hermes…) — off the Claude Code hook,
  # where it took >30s per tool call. Resumes from ai_logs_last_parsed_at:
  # ~1s after a short gap, ~80s after 2h.
  systemd.user.services.wakatime-ai-sync = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Sync AI agent activity to WakaTime/Wakapi";
    Service = {
      Type = "oneshot";
      ExecStart = "${unstablePkgs.wakatime-cli}/bin/wakatime-cli --sync-ai-activity --plugin Claude-Code-wakatime/1.0";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };
  systemd.user.timers.wakatime-ai-sync = lib.mkIf pkgs.stdenv.isLinux {
    Unit.Description = "Periodic WakaTime AI activity sync";
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # ~/.wakatime.cfg — written from agenix-managed encrypted INI.
  # Plugins (Cursor, VS Code, Zed, Vim, browser ext, Claude Code hook) all
  # read this file. Editor-specific wiring lives in ./editors.nix.
  home.activation.wakatimeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -f "${config.age.secrets.wakatime-cfg.path}" ]; then
      run install -m 600 "${config.age.secrets.wakatime-cfg.path}" "$HOME/.wakatime.cfg"
    fi
  '';
}
