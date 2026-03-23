{ pkgs, ... }:
{
  # Textfile collector directory — world-readable so node_exporter (DynamicUser)
  # can read .prom files; root-owned so only privileged services can write here.
  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter-textfile 0755 root root -"
  ];

  # Runs as root to query fail2ban's unix socket, writes .prom for node_exporter.
  systemd.services.fail2ban-metrics = {
    description = "Export fail2ban ban statistics for node_exporter";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "fail2ban-metrics" ''
        set -euo pipefail
        OUTFILE=/var/lib/node-exporter-textfile/fail2ban.prom
        TMP=$(mktemp)
        trap 'rm -f "$TMP"' EXIT
        {
          printf '# HELP fail2ban_banned_ips Currently banned IPs per jail\n'
          printf '# TYPE fail2ban_banned_ips gauge\n'
          printf '# HELP fail2ban_total_banned Total IPs ever banned per jail (cumulative)\n'
          printf '# TYPE fail2ban_total_banned counter\n'
          printf '# HELP fail2ban_failed_current Current failed auth attempts per jail\n'
          printf '# TYPE fail2ban_failed_current gauge\n'
          printf '# HELP fail2ban_total_failed Total failed auth attempts per jail (cumulative)\n'
          printf '# TYPE fail2ban_total_failed counter\n'
          for jail in $(${pkgs.fail2ban}/bin/fail2ban-client status \
                        | ${pkgs.gawk}/bin/awk -F: '/Jail list/{gsub(/[ \t]/,""); print $2}' \
                        | tr ',' '\n'); do
            status=$(${pkgs.fail2ban}/bin/fail2ban-client status "$jail" 2>/dev/null) || continue
            banned=$(printf '%s' "$status"       | ${pkgs.gawk}/bin/awk '/Currently banned/{print $NF}')
            total_banned=$(printf '%s' "$status" | ${pkgs.gawk}/bin/awk '/Total banned/{print $NF}')
            failed=$(printf '%s' "$status"       | ${pkgs.gawk}/bin/awk '/Currently failed/{print $NF}')
            total_failed=$(printf '%s' "$status" | ${pkgs.gawk}/bin/awk '/Total failed/{print $NF}')
            printf 'fail2ban_banned_ips{jail="%s"} %s\n'     "$jail" "''${banned:-0}"
            printf 'fail2ban_total_banned{jail="%s"} %s\n'   "$jail" "''${total_banned:-0}"
            printf 'fail2ban_failed_current{jail="%s"} %s\n' "$jail" "''${failed:-0}"
            printf 'fail2ban_total_failed{jail="%s"} %s\n'   "$jail" "''${total_failed:-0}"
          done
        } > "$TMP"
        mv "$TMP" "$OUTFILE"
        chmod 644 "$OUTFILE"
      '';
    };
  };

  systemd.timers.fail2ban-metrics = {
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "30s";
      OnUnitActiveSec = "1m";
    };
  };
}
