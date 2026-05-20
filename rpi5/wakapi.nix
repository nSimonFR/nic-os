# rpi5/wakapi.nix — self-hosted WakaTime-compatible coding stats backend.
#
# Internal HTTP: 127.0.0.1:3031 (backend; wakapi binds here)
# Tailnet     : Tailscale Serve → 127.0.0.1:3030 → socket-activate proxy
#               → backend on 3031. After 600s of HTTP idleness, wakapi
#               stops and frees ~13 MB; next IDE heartbeat wakes it.
# Storage     : SQLite at /var/lib/wakapi/wakapi.db (DynamicUser → /var/lib/private/wakapi).
# Daily backup at 03:45 → /mnt/data/backups/wakapi/ (picked up by storj-backup).
{ config, pkgs, lib, tailnetFqdn, ... }:
let
  externalPort = 3030;
  backendPort  = 3031;
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
        port = backendPort;
        public_url = "https://${tailnetFqdn}:${toString externalPort}";
      };
      db = {
        dialect = "sqlite3";
        name = "wakapi.db";
      };
      security = {
        allow_signup = false;
        insecure_cookies = false;
      };
      # Disable wakapi's built-in scheduled wakatime.com importer.
      # Why: wakatime.com warned us twice (2026-05-18, 2026-05-19) about the daily
      # POST to /api/v1/users/current/data_dumps that the binary fires at 04:15
      # whenever a user has a wakatime_api_key saved. The user-account key was
      # also cleared, but this disables the scheduler at the source.
      app = {
        import_enabled = false;
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

  # ── Socket-activated idle sleep (rpi5/lib/socket-activate.nix) ────────
  # IDE heartbeats are fire-and-forget POSTs; first one after sleep will be
  # slow then the wakapi binary stays warm for the editing session.
  #
  # readyProbe is required: wakapi runs DB migrations on startup (~1s on
  # a warm SQLite cache) before binding the listen socket. Without the
  # probe, the proxy races the listen() and the first heartbeat fails.
  services.socketActivate.wakapi = {
    enable    = true;
    realUnit  = "wakapi.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/api/health";
      expectStatus = 200;
      timeoutSec   = 30;
    };
  };

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
