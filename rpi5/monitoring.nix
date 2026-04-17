{ config, pkgs, lib, telegramChatId, ... }:
let
  beszelHubPort = 8090;
  beszelAgentPort = 45876;

  telegramNotify = pkgs.writeShellScript "telegram-notify" ''
    TOKEN=$(< ${config.age.secrets.telegram-bot-token.path})
    MSG="$1"
    ${pkgs.curl}/bin/curl -sf -X POST \
      "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id=${toString telegramChatId} \
      -d parse_mode=HTML \
      -d text="$MSG"
  '';
in
{
  # ── Beszel Hub ───────────────────────────────────────────────────────────────
  systemd.services.beszel-hub = {
    description = "Beszel monitoring hub";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.beszel}/bin/beszel-hub serve --http 127.0.0.1:${toString beszelHubPort}";
      DynamicUser = true;
      StateDirectory = "beszel-hub";
      WorkingDirectory = "/var/lib/beszel-hub";
      Restart = "on-failure";
      RestartSec = "5s";
      Environment = [ "GOMAXPROCS=2" ];
    };
  };

  # ── Beszel Agent ─────────────────────────────────────────────────────────────
  systemd.services.beszel-agent = {
    description = "Beszel monitoring agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "beszel-hub.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      DynamicUser = true;
      EnvironmentFile = "/var/lib/beszel-hub/agent.env";
      Restart = "on-failure";
      RestartSec = "10s";
      ConditionPathExists = "/var/lib/beszel-hub/agent.env";
      Environment = [
        "PORT=${toString beszelAgentPort}"
        "FILESYSTEM=/dev/disk/by-label/NIXOS_SSD,/dev/md/rpi5:home"
        "BESZEL_AGENT_PRIMARY_SENSOR=cpu_thermal"
      ];
      ProtectProc = "default";
    };
  };

  # ── Alert: systemd failed units ──────────────────────────────────────────────
  systemd.services.systemd-failed-alert = {
    description = "Alert on failed systemd units";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "systemd-failed-alert" ''
        FAILED=$(${pkgs.systemd}/bin/systemctl list-units --state=failed --no-legend)
        if [ -n "$FAILED" ]; then
          ${telegramNotify} "<b>systemd units failed on rpi5</b>
$FAILED"
        fi
      '';
    };
  };
  systemd.timers.systemd-failed-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";
    };
  };

  # ── Alert: HTTP health checks ────────────────────────────────────────────────
  systemd.services.http-health-alert = {
    description = "Alert on unhealthy HTTP services";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "http-health-alert" ''
        CURL="${pkgs.curl}/bin/curl"
        FAILURES=""
        $CURL -sf --max-time 10 http://127.0.0.1:18789/health > /dev/null 2>&1 || FAILURES="$FAILURES
- openclaw (18789/health)"
        $CURL -sf --max-time 10 http://127.0.0.1:${toString beszelHubPort}/api/health > /dev/null 2>&1 || FAILURES="$FAILURES
- beszel (${toString beszelHubPort}/api/health)"
        if [ -n "$FAILURES" ]; then
          ${telegramNotify} "<b>HTTP health check failed on rpi5</b>
$FAILURES"
        fi
      '';
    };
  };
  systemd.timers.http-health-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";
    };
  };

  # ── Alert: earlyoom kills ────────────────────────────────────────────────────
  systemd.services.earlyoom-alert = {
    description = "Alert on earlyoom OOM kills";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "earlyoom-alert" ''
        if ${pkgs.systemd}/bin/journalctl -u earlyoom --since=-3min --no-pager -q 2>/dev/null \
           | ${pkgs.gnugrep}/bin/grep -q "sending SIG"; then
          ${telegramNotify} "<b>earlyoom killed a process on rpi5</b>
Check <code>journalctl -u earlyoom</code> for details."
        fi
      '';
    };
  };
  systemd.timers.earlyoom-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";
    };
  };

  # ── Alert: read-only filesystem ──────────────────────────────────────────────
  systemd.services.filesystem-ro-alert = {
    description = "Alert on read-only filesystems";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "filesystem-ro-alert" ''
        RO_FS=$(${pkgs.gnugrep}/bin/grep -E 'ext4|xfs|btrfs' /proc/mounts \
                | ${pkgs.gnugrep}/bin/grep ' ro[, ]' || true)
        if [ -n "$RO_FS" ]; then
          ${telegramNotify} "<b>Read-only filesystem on rpi5</b>
<code>$RO_FS</code>"
        fi
      '';
    };
  };
  systemd.timers.filesystem-ro-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "5m";
    };
  };
}
