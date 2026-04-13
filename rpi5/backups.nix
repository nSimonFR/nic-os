# backups.nix — daily database backups to /mnt/data/backups/
# Each backup lands on the HDD so restic (storj-backup.nix) picks it up.
{ pkgs, lib, ... }:
let
  mkBackup = import ./lib/mk-backup.nix { inherit pkgs; };
in
{
  imports = [
    (mkBackup {
      name = "affine";
      type = "postgres";
      database = "affine";
    })
    (mkBackup {
      name = "sure";
      type = "postgres";
      database = "sure_production";
    })
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
}
