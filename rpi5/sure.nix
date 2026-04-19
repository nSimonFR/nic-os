{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, telegramChatId, ... }:
let
  port = 13334; # internal port; Tailscale Serve exposes this as HTTPS :3333 on the tailnet
in
{
  # ── for-sure: combined Swile + Sumeria Lunchflow connector ────────────────
  # Single service on port 8340; Sure connects to http://127.0.0.1:8340/api/v1
  services.sumeria-mitm = {
    enable           = true;
    exitNodeClients  = [ "100.112.22.60" ]; # nphone
    tokenFileGroup   = "for-sure";
  };

  services.for-sure = {
    enable                = true;
    port                  = 8340;
    apiKeyFile            = "/run/agenix/for-sure-api-key";
    swile.accountName     = "Swile";
    sumeria.tokenFile     = config.services.sumeria-mitm.tokenFile;
    telegram.botTokenFile = "/run/agenix/telegram-bot-token";
    telegram.chatId       = toString telegramChatId;
  };


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

  # Set sure_user password and DB ownership from agenix secret (ensurePasswordFile not
  # available in NixOS 25.11; use a oneshot service instead).
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
      ${pkgs.postgresql}/bin/psql -v pw="$password" -c "ALTER USER sure_user WITH PASSWORD :'pw';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE sure_production OWNER TO sure_user;"
    '';
  };

  # ── Sure application (native Nix, via sure-nix flake) ─────────────────────
  services.sure = {
    enable          = true;
    port            = port;
    environmentFile = "/run/agenix/sure-app-env";
    databaseUrl     = "postgresql://sure_user@${pgHost}/sure_production";
    redisUrl        = "redis://${redisHost}:${toString redisPort}/2";
  };

  # ── Sure memory optimizations ──────────────────────────────────────────────
  # Reduce Sidekiq concurrency (personal app, no need for 3 threads) and limit
  # glibc malloc arenas to curb RSS on a 4 GB RPi5.
  # Note: jemalloc was tested but increases RSS on aarch64 + Ruby YJIT.
  systemd.services.sure-worker.environment = {
    RAILS_MAX_THREADS = "1";
    MALLOC_ARENA_MAX  = "2";
    RUBY_YJIT_ENABLE  = "0";  # YJIT JIT-compiles into memory; not worth it for low-traffic personal app
  };
  systemd.services.sure-web.environment = {
    MALLOC_ARENA_MAX = "2";
    RUBY_YJIT_ENABLE = "0";
  };

  # sure-setup (migrations) must run after the password is set
  systemd.services.sure-setup = {
    after    = [ "sure-pg-setup.service" ];
    requires = [ "sure-pg-setup.service" ];
  };

}
