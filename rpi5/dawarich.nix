# dawarich.nix — self-hosted location history (Google Timeline alternative)
# Uses the native NixOS module (services.dawarich) — Rails + Sidekiq + PostGIS + Redis
{ config, pkgs, lib, tailnetFqdn, ... }:
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

    # Dedicated Redis instance via Unix socket (no port conflict with shared redis)
    redis.createLocally = true;

    # Auto-generate SECRET_KEY_BASE (stored at /var/lib/dawarich/secrets/secret-key-base)
    secretKeyBaseFile = null;

    # Reduce Sidekiq threads for RPi5 memory constraints
    sidekiqThreads = 3;

    environment = {
      TIME_ZONE = "Europe/Paris";
    };
  };

  # RPi5: PrivateUsers requires user namespaces, not supported on this kernel
  systemd.services.dawarich-web.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-sidekiq-all.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-init-db.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.dawarich-init-credentials.serviceConfig.PrivateUsers = lib.mkForce false;

  # Memory limits
  systemd.services.dawarich-web.serviceConfig.MemoryMax = "512M";
  systemd.services.dawarich-sidekiq-all.serviceConfig.MemoryMax = "512M";
}
