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

    # TimescaleDB, for freereps' hypertables (hosts/rpi5/freereps.nix). Its
    # first migration is `CREATE EXTENSION timescaledb` + four
    # create_hypertable() calls, so this is a hard dependency, not a tuning
    # choice — freereps cannot migrate without it.
    #
    # The APACHE edition deliberately. Plain `timescaledb` in nixpkgs is the
    # community build under the Timescale License and is marked unfree, which
    # this host would have to opt out of globally. FreeReps uses no TSL feature
    # — only hypertables and time_bucket, both Apache-licensed; there is no
    # compression policy, retention policy or continuous aggregate anywhere in
    # its migrations or queries (checked at bring-up). It also arrives prebuilt
    # from cache.nixos.org, where the community build would be a local compile.
    extensions = ps: with ps; [ timescaledb-apache ];
    # TCP needed for Docker --network=host containers (peer auth over unix socket doesn't work in Docker).
    # nixpkgs sets listen_addresses at regular priority via enableTCPIP; mkForce overrides it.
    settings = {
      listen_addresses = lib.mkForce pgHost;

      # ── TimescaleDB ───────────────────────────────────────────────────
      # A LIST, not a string, on purpose: the option's type is
      # `coercedTo (listOf str) (concatStringsSep ",") types.commas`, and
      # `commas` is a separatedString — so independent definitions MERGE into
      # one comma-joined value instead of colliding. The nixpkgs immich module
      # already declares `vchord.so` here for Immich's vector index; the
      # rendered postgresql.conf ends up with both. Writing a plain string (or
      # mkForce'ing one) would silently drop whichever the other module wanted
      # and break Immich's smart search.
      shared_preload_libraries = [ "timescaledb" ];

      # Default is 16 background workers, and TimescaleDB sizes this for a
      # server that is not also running Immich, AFFiNE, Sure, Dawarich and
      # Home Assistant on 4 GB. Each worker is a full Postgres backend
      # (17–23 MB RSS measured on this box). freereps has no compression or
      # retention jobs to run — only the per-database scheduler — so 2 is
      # generous. Stays under the default max_worker_processes = 8.
      "timescaledb.max_background_workers" = 2;

      # Belt and braces. nixpkgs builds with -DSEND_TELEMETRY_DEFAULT=false, so
      # the compiled-in default is already off — but it builds with
      # USE_TELEMETRY ON, so the reporting code and this GUC are both present
      # and one cmakeFlags change upstream would silently switch it back on.
      # Stating it here makes the answer independent of the build flags.
      "timescaledb.telemetry_level" = "off";

      # ── Memory tuning for 4 GiB RPi5 ──────────────────────────────────
      # Defaults (128 MB shared_buffers, 100 max_connections, 4 GB
      # effective_cache_size) are tuned for a much larger machine.
      shared_buffers       = "64MB";
      effective_cache_size = "512MB";
      work_mem             = "2MB";
      maintenance_work_mem = "32MB";
      max_connections      = 60;   # Immich alone holds ~19 idle (per-worker Prisma pools); 30 was saturating the pool
    };
  };

  services.redis.servers.${redisName} = {
    enable = true;
    bind   = redisHost;
    port   = redisPort;

    # ── Memory tuning for 4 GiB RPi5 ──────────────────────────────────
    # Shared by AFFiNE (DB 0), Immich (DB 1), Dawarich (DB 3).
    # Cap memory to prevent unbounded growth; LRU evicts least-recently-used
    # keys across all DBs when the limit is hit.
    settings = {
      maxmemory          = "128mb";
      maxmemory-policy   = "allkeys-lru";
    };
  };

  # Export shared connection values so other modules reference them instead of hardcoding.
  _module.args = {
    inherit pgHost pgPort redisHost redisPort redisName;
  };
}
