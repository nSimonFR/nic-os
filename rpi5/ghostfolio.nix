{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.ghostfolio;
  port = 3333;
  dataDir = "/var/lib/ghostfolio";
in
{
  options.services.ghostfolio = {
    enable = lib.mkEnableOption "Ghostfolio wealth management service";

    port = lib.mkOption {
      type = lib.types.int;
      default = port;
      description = "Port on which Ghostfolio listens";
    };
  };

  config = lib.mkIf cfg.enable {
    services.redis.servers.ghostfolio = {
      enable = true;
      bind = "127.0.0.1";
      port = 6379;
    };

    services.postgresql = {
      enable = true;
      ensureDatabases = [ "ghostfolio" ];
      ensureUsers = [
        {
          name = "ghostfolio";
          ensureDBOwnership = true;
        }
      ];
    };

    # System user for ghostfolio service
    users.users.ghostfolio = {
      isSystemUser = true;
      group = "ghostfolio";
      home = dataDir;
      createHome = true;
    };
    users.groups.ghostfolio = { };

    # Systemd service for Ghostfolio
    systemd.services.ghostfolio = {
      description = "Ghostfolio - Wealth Management Software";
      after = [ "network-online.target" "postgresql.service" "redis-ghostfolio.service" ];
      wants = [ "network-online.target" "postgresql.service" "redis-ghostfolio.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        NODE_ENV = "production";
        HOST = "127.0.0.1";
        PORT = toString cfg.port;
        DATABASE_URL = "postgresql://ghostfolio@localhost/ghostfolio?host=/run/postgresql";
        # Ghostfolio-specific env vars
        # Reduce Yahoo Finance request pressure to avoid 429 throttling.
        CACHE_QUOTES_TTL = "900000"; # 15 minutes in milliseconds
        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
      };

      serviceConfig = {
        Type = "simple";
        User = "ghostfolio";
        Group = "ghostfolio";
        WorkingDirectory = dataDir;
        EnvironmentFile = [ "${dataDir}/secrets.env" ];
        ExecStart = "${pkgs.ghostfolio}/bin/ghostfolio";
        Restart = "on-failure";
        RestartSec = "5s";
        StandardOutput = "journal";
        StandardError = "journal";
        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ dataDir ];
      };
    };

    # Initialize database directory and set permissions
    system.activationScripts.ghostfolio-init = ''
      mkdir -p ${dataDir}

      if [ ! -f "${dataDir}/secrets.env" ]; then
        access_token_salt="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        jwt_secret_key="$(${pkgs.openssl}/bin/openssl rand -hex 64)"
        cat > "${dataDir}/secrets.env" <<EOF
ACCESS_TOKEN_SALT=$access_token_salt
JWT_SECRET_KEY=$jwt_secret_key
EOF
      fi

      chown ghostfolio:ghostfolio ${dataDir}
      chmod 750 ${dataDir}
      chown ghostfolio:ghostfolio "${dataDir}/secrets.env"
      chmod 640 "${dataDir}/secrets.env"
    '';
  };
}
