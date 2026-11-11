# Tuwunel — the Matrix homeserver every bridge, client and the messaging MCP
# talk to (replaces Beeper's hosted one). Tailnet-only, no federation, one human
# account: @nico. Rooms the bridges create stay unencrypted, so the MCP reads
# them with plain HTTP.
#
# First boot creates @nico with a random password printed once in the journal
# (`journalctl -u tuwunel | grep -i password`); change it from the client.
{
  config,
  lib,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  inherit (config.nic.messaging) serverName homeserverPort appserviceDir;
  inherit (config.nic.messaging) cinnyPort;
  backupDir = "/mnt/data/backups/tuwunel";
in
{
  options.nic.messaging = {
    serverName = lib.mkOption {
      type = lib.types.str;
      # Suffix of every user and room id: cannot change once the server has run.
      default = tailnetFqdn;
      readOnly = true;
    };
    homeserverPort = lib.mkOption {
      type = lib.types.port;
      default = 6167;
      readOnly = true;
    };
    cinnyPort = lib.mkOption {
      type = lib.types.port;
      default = 13360;
      readOnly = true;
      description = "Loopback nginx vhost: Cinny plus the /_matrix proxy (cinny.nix).";
    };
    appserviceDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/matrix-appservices";
      readOnly = true;
      description = "Registration files Tuwunel loads at start, one per bridge.";
    };
  };

  config = {
    services.matrix-tuwunel = {
      enable = true;
      settings.global = {
        server_name = serverName;
        address = [ "127.0.0.1" ];
        port = [ homeserverPort ];
        allow_federation = false;
        allow_registration = false;
        # Clients create DMs encrypted by default, and the bridges refuse
        # encrypted rooms. Off: createRoom silently drops m.room.encryption.
        allow_encryption = false;
        trusted_servers = [ ];
        appservice_dir = appserviceDir;
        well_known.client = config.nic.services.matrix.public.publicUrl;

        # Defaults scale with core count (128 + 64×4 MB of RocksDB cache here).
        db_cache_capacity_mb = 32.0;
        cache_capacity_modifier = 0.25;

        # Fails harmlessly once the user exists.
        admin_execute = [ "users create-user nico" ];
        admin_execute_errors_ignore = true;

        # Online RocksDB backup, triggered by tuwunel-backup's SIGUSR2.
        database_backup_path = backupDir;
        database_backups_to_keep = 2;
        admin_signal_execute = [ "server backup-database" ];
      };
    };

    users.groups.matrix-appservices = { };
    systemd.tmpfiles.rules = [
      "d ${appserviceDir} 0750 root matrix-appservices -"
      "d ${backupDir} 0700 tuwunel tuwunel -"
    ];
    systemd.services.tuwunel = {
      serviceConfig = {
        SupplementaryGroups = [ "matrix-appservices" ];
        ReadWritePaths = [ backupDir ];
      };
      unitConfig.RequiresMountsFor = [ backupDir ];
    };

    systemd.services.tuwunel-backup = {
      description = "Tuwunel online database backup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl kill --signal=SIGUSR2 tuwunel.service";
      };
    };
    systemd.timers.tuwunel-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "*-*-* 03:20:00";
    };

    nic.services.matrix = {
      backup = [ "unit" ];
      backupUnits = [ "tuwunel-backup.service" ];
      # Cinny at /, the homeserver under /_matrix: one origin for every client.
      public = {
        order = 270;
        port = 4040;
        backend = "http://127.0.0.1:${toString cinnyPort}";
        funnel = false;
        tile = null;
      };
    };
  };
}
