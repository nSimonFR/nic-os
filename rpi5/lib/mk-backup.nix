# mk-backup.nix — generates a daily backup timer + service + tmpfiles rule.
#
# Usage:
#   mkBackup { name = "affine"; type = "postgres"; database = "affine"; }
#   mkBackup { name = "hass"; type = "sqlite"; path = "/var/lib/hass/home-assistant_v2.db"; user = "hass"; }
#   mkBackup { name = "vaultwarden"; type = "file"; path = "/var/backup/vaultwarden/db.sqlite3"; user = "vaultwarden";
#              extraFiles = [ "/var/backup/vaultwarden/rsa_key.pem" ]; calendar = "*-*-* 03:15:00"; }
{ pkgs }:
{ name
, type           # "postgres" | "sqlite" | "file"
, database ? ""  # postgres DB name
, path ? ""      # sqlite/file source path
, user ? (if type == "postgres" then "postgres" else name)
, extraFiles ? []
, calendar ? "*-*-* 03:00:00"
, retention ? 7  # days to keep old backups
}:
let
  backupDir = "/mnt/data/backups/${name}";
  ext = if type == "postgres" then "sql.gz" else "db.gz";

  dumpCmd = {
    postgres = ''
      ${pkgs.postgresql}/bin/pg_dump ${database} | ${pkgs.gzip}/bin/gzip > "${backupDir}/${name}-$STAMP.${ext}"
    '';
    sqlite = ''
      ${pkgs.sqlite}/bin/sqlite3 ${path} ".backup '${backupDir}/${name}-$STAMP.db'"
      ${pkgs.gzip}/bin/gzip -f "${backupDir}/${name}-$STAMP.db"
    '';
    file = ''
      ${pkgs.gzip}/bin/gzip -c ${path} > "${backupDir}/${name}-$STAMP.${ext}"
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
      ${pkgs.findutils}/bin/find "${backupDir}" -name "${name}-*.${ext}" -mtime +${toString retention} -delete
    '';
  } // (if type == "postgres" then {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
  } else {});

  systemd.timers."${name}-backup" = {
    description = "Daily ${name} backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = calendar;
      Persistent = true;
    };
  };
}
