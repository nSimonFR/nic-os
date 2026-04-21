# dawarich.nix — self-hosted location history (Google Timeline alternative)
# Uses the native NixOS module (services.dawarich) — Rails + Sidekiq + PostGIS + Redis
{ config, pkgs, lib, tailnetFqdn, redisHost, redisPort, ... }:
let
  internalPort = 13900;
in
{
  services.dawarich = {
    enable = true;
    localDomain = tailnetFqdn;
    webPort = internalPort;
    configureNginx = false; # Tailscale Serve handles HTTPS

    # Reuses existing PostgreSQL cluster; auto-adds "dawarich" DB + PostGIS extension
    database.createLocally = true;

    # Use the shared Redis (databases.nix) on DB 3 via TCP instead of a
    # dedicated redis-dawarich instance. Saves ~7 MB RAM + one systemd unit.
    redis = {
      createLocally = false;
      host          = redisHost;
      port          = redisPort;
    };

    # Auto-generate SECRET_KEY_BASE (stored at /var/lib/dawarich/secrets/secret-key-base)
    secretKeyBaseFile = null;

    # Reduce Sidekiq threads for RPi5 memory constraints
    sidekiqThreads = 1;

    environment = {
      TIME_ZONE = "Europe/Paris";
      # Single-process Puma (no forked workers) — saves ~50 MB on RPi5
      WEB_CONCURRENCY = "0";
      # Match reduced thread count for web process
      RAILS_MAX_THREADS = "2";
      # Limit jemalloc memory arenas
      MALLOC_ARENA_MAX = "2";
      # Override upstream's REDIS_URL (which has no DB index) to isolate
      # Dawarich's keyspace on DB 3 of the shared Redis.
      REDIS_URL = "redis://${redisHost}:${toString redisPort}/3";
    };
  };

  # RPi5: PrivateUsers requires user namespaces, not supported on this kernel
  systemd.services.dawarich-web.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-sidekiq-all.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-init-db.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-init-credentials.serviceConfig.PrivateUsers = lib.mkForce false;

  # Memory limits — tightened for single-process mode
  systemd.services.dawarich-web.serviceConfig.MemoryMax = "256M";
  systemd.services.dawarich-sidekiq-all.serviceConfig.MemoryMax = "256M";
}
