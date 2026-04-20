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
    # smartctl on PATH so Beszel can collect SMART data from /dev/sda + /dev/sdb.
    path = [ pkgs.smartmontools ];
    unitConfig.ConditionPathExists = "/var/lib/beszel-hub/agent.env";
    serviceConfig = {
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      DynamicUser = true;
      EnvironmentFile = "/var/lib/beszel-hub/agent.env";
      Restart = "on-failure";
      RestartSec = "10s";
      Environment = [
        "PORT=${toString beszelAgentPort}"
        "FILESYSTEM=/dev/sdb1,/dev/sdb2,/dev/sda1"
        "BESZEL_AGENT_PRIMARY_SENSOR=cpu_thermal"
        # Pin SMART devices (smartctl --scan confirms these types):
        #   /dev/sda — Hitachi HDD over USB-SATA bridge → SAT translation
        #   /dev/sdb — HP SSD EX900 (NVMe) in Realtek USB-NVMe enclosure → sntrealtek
        "SMART_DEVICES=/dev/sda:sat,/dev/sdb:sntrealtek"
        "SMART_INTERVAL=1h"
      ];
      ProtectProc = "default";
      # SMART access: CAP_SYS_RAWIO for SG_IO ioctls (SATA), CAP_SYS_ADMIN for
      # NVMe admin passthrough (none present today but cheap to have).
      # Ambient caps required because DynamicUser=true means beszel-agent runs
      # as an unprivileged user; bounding-set alone would be insufficient.
      AmbientCapabilities    = [ "CAP_SYS_RAWIO" "CAP_SYS_ADMIN" ];
      CapabilityBoundingSet  = [ "CAP_SYS_RAWIO" "CAP_SYS_ADMIN" ];
      # Allow read access to the raw block devices.
      DeviceAllow            = [ "/dev/sda r" "/dev/sdb r" ];
      SupplementaryGroups    = [ "disk" ];
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
        $CURL -sf --max-time 10 http://127.0.0.1:13900/api/v1/health > /dev/null 2>&1 || FAILURES="$FAILURES
- dawarich (13900/api/v1/health)"
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
        KILL_LINE=$(${pkgs.systemd}/bin/journalctl -u earlyoom --since=-3min --no-pager -q 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep "sending SIG" \
          | ${pkgs.coreutils}/bin/tail -n 1 || true)

        if [ -n "$KILL_LINE" ]; then
          PROC=$(${pkgs.gnused}/bin/sed -n 's/.*process \([0-9]\+\).*"\([^"]\+\)".*/\2/p' <<< "$KILL_LINE")
          PID=$(${pkgs.gnused}/bin/sed -n 's/.*process \([0-9]\+\).*/\1/p' <<< "$KILL_LINE")
          RSS=$(${pkgs.gnused}/bin/sed -n 's/.*VmRSS \([0-9]\+ MiB\).*/\1/p' <<< "$KILL_LINE")
          CMD=$(${pkgs.gnused}/bin/sed -n 's/.*cmdline "\([^"]*\)".*/\1/p' <<< "$KILL_LINE" | ${pkgs.coreutils}/bin/cut -c1-160)

          MSG="<b>earlyoom killed a process on rpi5</b>"
          [ -n "$PROC" ] && MSG="$MSG
- process: <code>$PROC</code>"
          [ -n "$PID" ] && MSG="$MSG
- pid: <code>$PID</code>"
          [ -n "$RSS" ] && MSG="$MSG
- rss: <code>$RSS</code>"
          [ -n "$CMD" ] && MSG="$MSG
- cmd: <code>$CMD</code>"

          ${telegramNotify} "$MSG"
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
                | ${pkgs.gnugrep}/bin/grep -v '/nix/store' \
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

  # ── Beszel SMART refresh (workaround for henrygd/beszel#1800) ───────────────
  # TODO(beszel#1800): DELETE THIS WHOLE BLOCK (service + timer) once Beszel
  #   0.19.0+ with a verified fix lands in nixpkgs and a natural background
  #   SMART fetch is observed in the hub _logs. Issue:
  #   https://github.com/henrygd/beszel/issues/1800
  #
  # Beszel 0.18.6's background SMART fetcher in update() doesn't reliably fire
  # on SMART_INTERVAL — data.Details.SmartInterval isn't transmitted over SSH
  # correctly, the hub falls back to a 1h default + cooldown that effectively
  # blocks subsequent fetches. The manual refresh endpoint bypasses the
  # cooldown and always works.
  #
  # The homepage superuser (created for the Beszel homepage widget) is reused
  # here for the API login; password is plain in homepage.nix:81.
  systemd.services.beszel-smart-refresh = {
    description = "Refresh Beszel SMART data for all systems (workaround for beszel#1800)";
    after = [ "beszel-hub.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "beszel-smart-refresh" ''
        set -eu
        CURL="${pkgs.curl}/bin/curl"
        JQ="${pkgs.jq}/bin/jq"
        HUB=http://127.0.0.1:${toString beszelHubPort}

        TOKEN=$($CURL -sf -X POST "$HUB/api/collections/_superusers/auth-with-password" \
          -H 'Content-Type: application/json' \
          -d '{"identity":"homepage@nic-os.local","password":"homepage-widget-pass"}' \
          | $JQ -r .token)

        # Disable PocketBase's built-in "new login location" email alert on the
        # _superusers collection. Otherwise our hourly login triggers a sendmail
        # call that fails (no MTA configured) and logs a recordAuthResponse
        # error each run. Idempotent — safe to run every tick.
        $CURL -sf -X PATCH "$HUB/api/collections/_superusers" \
          -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
          -d '{"authAlert":{"enabled":false}}' > /dev/null \
          && echo "authAlert disabled on _superusers" \
          || echo "WARN: failed to disable authAlert" >&2

        # Iterate over every registered system and kick its manual SMART refresh.
        SYSTEMS=$($CURL -sf -H "Authorization: $TOKEN" \
          "$HUB/api/collections/systems/records?perPage=100&fields=id,name,status" \
          | $JQ -r '.items[] | select(.status=="up") | .id')

        for id in $SYSTEMS; do
          $CURL -sf -X POST -H "Authorization: $TOKEN" \
            "$HUB/api/beszel/smart/refresh?system=$id" > /dev/null \
            && echo "refreshed SMART for system=$id" \
            || echo "WARN: refresh failed for system=$id" >&2
        done
      '';
    };
  };
  systemd.timers.beszel-smart-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Wait 3m after boot so beszel-hub has time to accept the initial SSH
      # handshake from beszel-agent and populate the systems list.
      OnBootSec = "3m";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
