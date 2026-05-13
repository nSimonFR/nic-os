# rpi5/wakapi.nix — self-hosted WakaTime-compatible coding stats backend.
#
# Internal HTTP: 127.0.0.1:3030
# Tailnet: Tailscale Serve proxies as HTTPS :3030 (see services-registry.nix).
# Storage: SQLite at /var/lib/wakapi/wakapi.db (DynamicUser → /var/lib/private/wakapi).
# Daily backup at 03:45 → /mnt/data/backups/wakapi/ (picked up by storj-backup).
{ config, pkgs, lib, tailnetFqdn, ... }:
let
  port = 3030;
in {
  services.wakapi = {
    enable = true;
    passwordSaltFile = "/run/agenix/wakapi-password-salt";
    # SMTP password (Proton Bridge token) supplied via EnvironmentFile as
    # WAKAPI_MAIL_SMTP_PASS, see secrets.nix → wakapi-smtp-env.
    smtpPasswordFile = "/run/agenix/wakapi-smtp-env";
    settings = {
      server = {
        listen_ipv4 = "127.0.0.1";
        port = port;
        public_url = "https://${tailnetFqdn}:${toString port}";
      };
      db = {
        dialect = "sqlite3";
        name = "wakapi.db";
      };
      security = {
        allow_signup = false;
        insecure_cookies = false;
      };
      mail = {
        enabled = true;
        provider = "smtp";
        sender = "Wakapi <nsimon@protonmail.com>";
        smtp = {
          host = "127.0.0.1";
          port = 1025;
          username = "nsimon@protonmail.com";
          # password injected via EnvironmentFile (WAKAPI_MAIL_SMTP_PASS).
          tls = false; # hydroxide bridge is plaintext on localhost
        };
      };
    };
  };

  # Wait for hydroxide before starting wakapi so SMTP is reachable.
  systemd.services.wakapi = {
    after = [ "hydroxide.service" ];
    wants = [ "hydroxide.service" ];
  };

  # PrivateUsers (nixpkgs default) needs user namespaces — unsupported on RPi5.
  systemd.services.wakapi.serviceConfig.PrivateUsers = lib.mkForce false;

  # ── Daily SQLite backup → /mnt/data/backups/wakapi ──
  systemd.tmpfiles.rules = [
    "d /mnt/data/backups/wakapi 0750 root root -"
  ];

  systemd.services.wakapi-backup = {
    description = "Wakapi SQLite database backup";
    serviceConfig = { Type = "oneshot"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/wakapi/wakapi.db \
        ".backup '/mnt/data/backups/wakapi/wakapi-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/wakapi/wakapi-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/wakapi -name "wakapi-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.wakapi-backup = {
    description = "Daily Wakapi backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:45:00"; Persistent = true; };
  };
}
