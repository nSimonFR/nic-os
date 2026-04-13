# backups.nix — daily database backups to /mnt/data/backups/
# Each backup lands on the HDD so restic (storj-backup.nix) picks it up.
#
# PostgreSQL: built-in services.postgresqlBackup module
# SQLite/files: mkBackup helper (lib/mk-backup.nix)
{ pkgs, lib, ... }:
let
  mkBackup = import ./lib/mk-backup.nix { inherit pkgs; };
in
{
  imports = [
    (mkBackup {
      name = "hass";
      type = "sqlite";
      path = "/var/lib/hass/home-assistant_v2.db";
      user = "hass";
    })
    (mkBackup {
      name = "vaultwarden";
      type = "file";
      path = "/var/backup/vaultwarden/db.sqlite3";
      user = "vaultwarden";
      extraFiles = [ "/var/backup/vaultwarden/rsa_key.pem" ];
      calendar = "*-*-* 03:15:00"; # after vaultwarden's own hot backup
    })
  ];

  # PostgreSQL backups via built-in NixOS module
  services.postgresqlBackup = {
    enable = true;
    location = "/mnt/data/backups/postgresql";
    databases = [ "affine" "sure_production" ];
    compression = "gzip";
    startAt = "*-*-* 03:00:00";
  };
}
