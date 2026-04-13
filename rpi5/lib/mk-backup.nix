# mk-backup.nix — generates a daily backup timer + service + tmpfiles rule
# for SQLite databases or plain files. For PostgreSQL, use the built-in
# services.postgresqlBackup module instead.
#
# Usage:
#   mkBackup { name = "hass"; type = "sqlite"; path = "/var/lib/hass/home-assistant_v2.db"; user = "hass"; }
#   mkBackup { name = "vaultwarden"; type = "file"; path = "/var/backup/vaultwarden/db.sqlite3"; user = "vaultwarden";
#              extraFiles = [ "/var/backup/vaultwarden/rsa_key.pem" ]; calendar = "*-*-* 03:15:00"; }
{ pkgs }:
{ name
, type           # "sqlite" | "file"
, path           # source path
, user ? name
, extraFiles ? []
, calendar ? "*-*-* 03:00:00"
, retention ? 7  # days to keep old backups
}:
let
  backupDir = "/mnt/data/backups/${name}";

  dumpCmd = {
    sqlite = ''
      ${pkgs.sqlite}/bin/sqlite3 ${path} ".backup '${backupDir}/${name}-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "${backupDir}/${name}-$STAMP.db"
    '';
    file = ''
      ${pkgs.gzip}/bin/gzip -c ${path} > "${backupDir}/${name}-$STAMP.db.gz"
    '';
  }.${type};

  copyExtras = builtins.concatStringsSep "\n" (
    map (f: ''${pkgs.coreutils}/bin/cp ${f} "${backupDir}/"'') extraFiles
  );
in
{
  systemd.tmpfiles.rules = [
    "d ${backupDir} 0750 ${user} ${user} -"
  ];

  systemd.services."${name}-backup" = {
    description = "${name} database backup";
    serviceConfig = {
      Type = "oneshot";
      User = user;
    };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      ${dumpCmd}
      ${copyExtras}
      ${pkgs.findutils}/bin/find "${backupDir}" -name "${name}-*.db.gz" -mtime +${toString retention} -delete
    '';
  };

  systemd.timers."${name}-backup" = {
    description = "Daily ${name} backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = calendar;
      Persistent = true;
    };
  };
}
