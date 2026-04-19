# backups.nix — daily database backups to /mnt/data/backups/
# Each backup lands on the HDD so restic (storj-backup.nix) picks it up.
{ pkgs, ... }:
{
  # ── PostgreSQL (built-in NixOS module) ─────────────────────────────────
  services.postgresqlBackup = {
    enable = true;
    location = "/mnt/data/backups/postgresql";
    databases = [ "affine" "dawarich" "sure_production" ];
    compression = "gzip";
    startAt = "*-*-* 03:00:00";
  };

  # ── SQLite backups ─────────────────────────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /mnt/data/backups/hass 0750 hass hass -"
    "d /mnt/data/backups/vaultwarden 0750 vaultwarden vaultwarden -"
    "d /mnt/data/backups/open-webui 0750 root root -"
  ];

  systemd.services.hass-backup = {
    description = "Home Assistant database backup";
    serviceConfig = { Type = "oneshot"; User = "hass"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/hass/home-assistant_v2.db ".backup '/mnt/data/backups/hass/hass-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/hass/hass-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/hass -name "hass-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.hass-backup = {
    description = "Daily Home Assistant backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:00:00"; Persistent = true; };
  };

  # ── Open WebUI (SQLite) ─────────────────────────────────────────────────
  systemd.services.open-webui-backup = {
    description = "Open WebUI database backup";
    serviceConfig = { Type = "oneshot"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/open-webui/data/webui.db ".backup '/mnt/data/backups/open-webui/webui-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "/mnt/data/backups/open-webui/webui-$STAMP.db"
      ${pkgs.findutils}/bin/find /mnt/data/backups/open-webui -name "webui-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.open-webui-backup = {
    description = "Daily Open WebUI backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:30:00"; Persistent = true; };
  };

  # ── Vaultwarden (file copy from built-in hot backup) ───────────────────
  systemd.services.vaultwarden-backup = {
    description = "Vaultwarden off-site backup";
    serviceConfig = { Type = "oneshot"; User = "vaultwarden"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${pkgs.gzip}/bin/gzip -c /var/backup/vaultwarden/db.sqlite3 > "/mnt/data/backups/vaultwarden/vaultwarden-$STAMP.db.gz"
      ${pkgs.coreutils}/bin/cp /var/backup/vaultwarden/rsa_key.pem /mnt/data/backups/vaultwarden/
      ${pkgs.findutils}/bin/find /mnt/data/backups/vaultwarden -name "vaultwarden-*.db.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.vaultwarden-backup = {
    description = "Daily Vaultwarden backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:15:00"; Persistent = true; };
  };
}
