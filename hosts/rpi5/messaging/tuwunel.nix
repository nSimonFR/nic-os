# Tuwunel — the Matrix homeserver every bridge, client and the messaging MCP
# talk to (replaces Beeper's hosted one). Tailnet-only, no federation, one human
# account: @nico. Rooms the bridges create stay unencrypted, so the MCP reads
# them with plain HTTP.
#
# First boot creates @nico with a random password printed once in the journal
# (`journalctl -u tuwunel | grep -i password`); change it from the client.
#
# SSO through Pocket ID, untrusted and without registration, so it only logs
# into accounts linked by hand. Linking @nico once: find his Pocket ID user id
# (the `sub` claim) in the admin UI, then in the admin room run
#   !admin query oauth associate tuwunel @nico:<serverName> --claim sub=<uuid>
# and log in with SSO before the next restart (pending links live in memory).
# Password login stays on as the fallback.
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
  inherit (config.nic.services.matrix.public) publicUrl;
  inherit (config.nic.sso.clients.tuwunel) secretFile;

  # Tuwunel refuses to start on a missing or empty client secret, so the
  # provider is only added (ExecStartPre) once pocket-id-clients wrote one.
  # Discovery runs at login, not at boot: Pocket ID down only fails SSO.
  ssoFragment = (pkgs.formats.toml { }).generate "tuwunel-sso.toml" {
    global.identity_provider = [
      {
        brand = "Pocket ID";
        name = "Pocket ID";
        client_id = "tuwunel";
        client_secret_file = ssoSecret;
        issuer_url = config.nic.sso.issuer;
        callback_url = "${publicUrl}/_matrix/client/unstable/login/sso/callback/tuwunel";
        trusted = false;
        registration = false;
        unique_id_fallbacks = false;
      }
    ];
  };
  ssoSecret = "/run/credentials/tuwunel.service/sso-client-secret";
  ssoConfig = "/run/tuwunel/sso.toml";
  ssoConfigScript = pkgs.writeShellApplication {
    name = "tuwunel-sso-config";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ -s ${ssoSecret} ]; then
        install -m 0444 ${ssoFragment} ${ssoConfig}
      else
        echo "tuwunel: no Pocket ID client secret, SSO off" >&2
        install -m 0444 /dev/null ${ssoConfig}
      fi
    '';
  };
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

        login_with_password = true;
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
        # DynamicUser: no static group can own the secret, systemd hands it over.
        # SetCredential is the fallback when the file is missing (not fatal).
        LoadCredential = [ "sso-client-secret:${secretFile}" ];
        SetCredential = [ "sso-client-secret:" ];
        ExecStartPre = [ "+${lib.getExe ssoConfigScript}" ];
        ExecStart = lib.mkForce "${lib.getExe' config.services.matrix-tuwunel.package "tuwunel"} -c ${ssoConfig}";
      };
      unitConfig.RequiresMountsFor = [ backupDir ];
      after = [ "pocket-id-clients.service" ];
      wants = [ "pocket-id-clients.service" ];
    };

    nic.sso.clients.tuwunel = {
      name = "Matrix";
      callbackUrls = [ "${publicUrl}/_matrix/client/unstable/login/sso/callback/tuwunel" ];
      launchUrl = publicUrl;
      secretGroup = "root"; # read by systemd (LoadCredential above)
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
        # Fourth tile of the last Apps row. The stats are the bridges', not
        # Cinny's: what reaches this client is what the bridges carry in.
        tile = {
          name = "Cinny";
          icon = "cinny.svg";
          category = "Apps";
          description = "Matrix chat + bridges";
          widget = {
            type = "customapi";
            url = "http://127.0.0.1:8087/matrix";
            refreshInterval = 3600000;
            mappings = [
              {
                field = "linked";
                label = "Bridges";
                format = "text";
              }
              {
                field = "chats";
                label = "Chats";
                format = "number";
              }
              {
                field = "messages_7d";
                label = "Msgs 7d";
                format = "number";
              }
            ];
          };
        };
      };
    };
  };
}
