{ pkgs, lib, pgHost, pgPort, redisHost, redisPort, ... }:
let
  port = 13334; # internal port; Tailscale Serve exposes this as HTTPS :3333 on the tailnet
  commonEnv = {
    DB_HOST       = pgHost;
    DB_PORT       = toString pgPort;
    POSTGRES_USER = "sure_user";
    POSTGRES_DB   = "sure_production";
    REDIS_URL     = "redis://${redisHost}:${toString redisPort}/2";
    SELF_HOSTED   = "true";
    RAILS_FORCE_SSL  = "false";
    RAILS_ASSUME_SSL = "false";
    PORT          = toString port;
  };
  secretsEnvFile = "/run/agenix/sure-app-env";
in
{
  # ── PostgreSQL: sure_production database + sure_user ──────────────────────
  services.postgresql = {
    ensureDatabases = [ "sure_production" ];
    ensureUsers = [{
      name = "sure_user";
      # ensureDBOwnership requires db name == username; we grant ownership in sure-pg-setup
    }];

    # Allow sure_user to connect via TCP with scram-sha-256 password auth
    authentication = lib.mkAfter ''
      host  sure_production  sure_user  ${pgHost}/32  scram-sha-256
    '';
  };

  # ── Sure containers (host networking → can reach 127.0.0.1:{5432,6379}) ──
  virtualisation.oci-containers.containers = {
    sure-web = {
      image = "ghcr.io/we-promise/sure:stable";
      environment = commonEnv;
      environmentFiles = [ secretsEnvFile ];
      extraOptions = [ "--network=host" ];
      dependsOn = []; # postgres/redis are host services, not containers
    };

    sure-worker = {
      image = "ghcr.io/we-promise/sure:stable";
      cmd   = [ "bundle" "exec" "sidekiq" ];
      environment = commonEnv;
      environmentFiles = [ secretsEnvFile ];
      volumes = [ "/var/lib/sure/storage:/rails/storage" ];
      extraOptions = [ "--network=host" ];
    };
  };

  # Set sure_user password from agenix secret (ensurePasswordFile not available
  # in this nixpkgs version; use a oneshot service instead).
  systemd.services.sure-pg-setup = {
    description = "Set sure_user PostgreSQL password";
    after    = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      password=$(cat /run/agenix/sure-pg-password)
      ${pkgs.postgresql}/bin/psql -c "ALTER USER sure_user WITH PASSWORD '$password';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE sure_production OWNER TO sure_user;"
    '';
  };

  # sure-web must start after postgres and password setup are ready
  systemd.services.docker-sure-web = {
    after    = [ "sure-pg-setup.service" ];
    requires = [ "sure-pg-setup.service" ];
  };
  systemd.services.docker-sure-worker = {
    after    = [ "sure-pg-setup.service" ];
    requires = [ "sure-pg-setup.service" ];
  };

  # Shared app storage directory (Active Storage uploads)
  systemd.tmpfiles.rules = [ "d /var/lib/sure/storage 0755 root root -" ];
}
