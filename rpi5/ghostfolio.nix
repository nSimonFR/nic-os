{
  config,
  lib,
  pkgs,
  redisHost,
  redisPort,
  redisName,
  ...
}:
let
  cfg = config.services.ghostfolio;
  port = 3333;
  dataDir = "/var/lib/ghostfolio";
  # Ghostfolio's build:production includes `nx run ui:build-storybook` which
  # consumes ~1.3 GiB peak RSS during TerserPlugin minification — too much for
  # RPi5 (4 GiB). Storybook is a dev UI and not needed at runtime. Patch it out.
  ghostfolioPkg = pkgs.ghostfolio.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace package.json \
        --replace-warn "&& nx run ui:build-storybook" ""
    '';
  });
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
    services.postgresql = {
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
      after = [ "network-online.target" "postgresql.service" "redis-${redisName}.service" ];
      wants = [ "network-online.target" "postgresql.service" "redis-${redisName}.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        NODE_ENV = "production";
        HOST = "127.0.0.1";
        PORT = toString cfg.port;
        # Cap V8 old-generation heap; forces GC before memory balloons.
        # 256M caused OOM crashes at startup (fresh RSS ~332M); 384M gives headroom
        # above startup allocation while still triggering GC well before MemoryMax=512M.
        NODE_OPTIONS = "--max-old-space-size=384";
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
        ExecStart = "${ghostfolioPkg}/bin/ghostfolio";
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
        # Memory limits: throttle before hard-killing.
        # RSS at fresh start is ~332MiB; cgroup accounting excludes shared libs so
        # the exclusive footprint is lower, but give generous headroom to avoid
        # spurious OOM kills on cache warm-up.
        MemoryHigh = "320M";
        MemoryMax  = "512M";
      };
    };

    # ── Prometheus exporters & scrapes ──────────────────────────────────────
    services.prometheus.exporters.postgres = {
      enable              = true;
      port                = 9187;
      listenAddress       = "127.0.0.1";
      runAsLocalSuperUser = true;
    };

    services.prometheus.exporters.redis = {
      enable        = true;
      port          = 9121;
      listenAddress = "127.0.0.1";
      extraFlags    = [ "--redis.addr redis://${redisHost}:${toString redisPort}" ];
    };

    services.prometheus.scrapeConfigs = [
      { job_name       = "postgres";
        static_configs = [{ targets = [ "127.0.0.1:9187" ]; }]; }
      { job_name       = "redis";
        static_configs = [{ targets = [ "127.0.0.1:9121" ]; }]; }
      # Blackbox HTTP probe for Ghostfolio
      { job_name       = "blackbox-ghostfolio";
        metrics_path   = "/probe";
        params         = { module = [ "http_2xx" ]; };
        static_configs = [{ targets = [ "http://127.0.0.1:${toString cfg.port}" ]; }];
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
        ]; }
    ];

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
