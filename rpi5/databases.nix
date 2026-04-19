{ lib, ... }:
let
  pgHost    = "127.0.0.1";
  pgPort    = 5432;
  redisHost = "127.0.0.1";
  redisPort = 6379;
  redisName = "shared";
in
{
  services.postgresql = {
    enable = true;
    # TCP needed for Docker --network=host containers (peer auth over unix socket doesn't work in Docker).
    # nixpkgs sets listen_addresses at regular priority via enableTCPIP; mkForce overrides it.
    settings = {
      listen_addresses = lib.mkForce pgHost;

      # ── Memory tuning for 4 GiB RPi5 ──────────────────────────────────
      # Defaults (128 MB shared_buffers, 100 max_connections, 4 GB
      # effective_cache_size) are tuned for a much larger machine.
      shared_buffers       = "64MB";
      effective_cache_size = "512MB";
      work_mem             = "2MB";
      maintenance_work_mem = "32MB";
      max_connections      = 30;   # only ~20 in use across all services
    };
  };

  services.redis.servers.${redisName} = {
    enable = true;
    bind   = redisHost;
    port   = redisPort;
  };

  # Export shared connection values so other modules reference them instead of hardcoding.
  _module.args = {
    inherit pgHost pgPort redisHost redisPort redisName;
  };
}
