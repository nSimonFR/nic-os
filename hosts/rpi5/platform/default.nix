# What every service stands on: databases, backups, deploys, alerting, beast's power.
{
  imports = [
    ./databases.nix
    ./monitoring.nix
    ./beast-power.nix # beast-wake + the four-hourly "beast is idling powered-on" backstop
    ./forgejo.nix
    ./cachix-agent.nix
    ./backups.nix
    ./auto-reboot.nix
    ./storj-backup.nix
  ];
}
