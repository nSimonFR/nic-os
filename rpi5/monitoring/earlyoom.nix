{ pkgs, ... }:
{
  # Textfile exporter: count earlyoom SIGTERM/SIGKILL events from the journal
  # and expose them as Prometheus counters so Grafana can alert on OOM kills.
  systemd.services.earlyoom-metrics = {
    description = "Export earlyoom kill statistics for node_exporter";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "earlyoom-metrics" ''
        set -euo pipefail
        OUTFILE=/var/lib/node-exporter-textfile/earlyoom.prom
        TMP=$(mktemp)
        trap 'rm -f "$TMP"' EXIT

        sigterm=$(journalctl -b 0 -u earlyoom --no-pager -q 2>/dev/null \
                  | grep -c "sending SIGTERM" || true)
        sigkill=$(journalctl -b 0 -u earlyoom --no-pager -q 2>/dev/null \
                  | grep -c "sending SIGKILL" || true)

        {
          printf '# HELP earlyoom_kills_sigterm_total Processes sent SIGTERM by earlyoom since boot\n'
          printf '# TYPE earlyoom_kills_sigterm_total counter\n'
          printf 'earlyoom_kills_sigterm_total %s\n' "''${sigterm:-0}"
          printf '# HELP earlyoom_kills_sigkill_total Processes sent SIGKILL by earlyoom since boot\n'
          printf '# TYPE earlyoom_kills_sigkill_total counter\n'
          printf 'earlyoom_kills_sigkill_total %s\n' "''${sigkill:-0}"
        } > "$TMP"
        mv "$TMP" "$OUTFILE"
        chmod 644 "$OUTFILE"
      '';
    };
  };

  systemd.timers.earlyoom-metrics = {
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "60s";
      OnUnitActiveSec = "1m";
    };
  };
}
