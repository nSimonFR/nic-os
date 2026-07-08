# dawarich.nix — self-hosted location history (Google Timeline alternative)
# Uses the native NixOS module (services.dawarich) — Rails + Sidekiq + PostGIS + Redis
#
# Exposure: Tailscale Serve on :3900 → :13900 (tailnet-only; NOT a Funnel).
# The tracking clients (Dawarich iOS/Android, OwnTracks, Overland, Traccar) post
# GPS to /api/v1/… over the tailnet, so no public origin is needed.
#
# Studied NSI-76 — "move behind the 443 front-proxy path-mux at /dawarich/"
# (like Nextcloud/Cyrus/Sure). REJECTED: not feasible with the stock package.
#   • Dawarich's map frontend hardcodes absolute, domain-root paths — api_client.js
#     `this.baseURL = "/api/v1"`, dozens of `fetch("/api/v1/…")`, the live-map
#     websocket `/cable?share_id=…`, vector styles `/maps_maplibre/styles/*.json`,
#     and turbo-nav to `/map/v2`. Worse, maps/places.js rebuilds the path via
#     `new URL("/api/v1/places", window.location.origin)` — origin is scheme+host
#     only, so it DISCARDS any prefix. Under /dawarich/ every map request 404s.
#   • RAILS_RELATIVE_URL_ROOT is not wired in (would only fix server-rendered
#     links/assets, never the JS above); a proxy sub_filter can't help either
#     because the paths are built dynamically from origin. Maintainer confirms
#     "no such functionality" (github.com/Freika/dawarich/discussions/330, #139).
#   • Same failure class as AFFiNE (see front-proxy.nix): an SPA that insists on
#     root paths can't be path-muxed. And there's no free Funnel port for a
#     dedicated root origin (443/8443/10000 are all taken).
# → Dawarich stays on tailnet-only Serve. (Public exposure would also hit the
#   documented /api/* auth-bypass trap, dawarich #2469.) Revisit only if upstream
#   adds a configurable base path or we fork+patch the frontend.
{ config, pkgs, lib, unstablePkgs, tailnetFqdn, redisHost, redisPort, ... }:
let
  internalPort = 13900;
in
{
  services.dawarich = {
    enable = true;
    # release-25.11's dawarich is frozen at 1.7.5; track the unstable package
    # for the latest release (mirrors immich in rpi5/immich.nix).
    package = unstablePkgs.dawarich;
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

  # Geoapify reverse geocoding — drives visit suggestions (nightly sidekiq job)
  # and on-demand address lookups in the web UI.
  # Key is injected via EnvironmentFile to keep it out of the nix store.
  systemd.services.dawarich-web.serviceConfig.EnvironmentFile =
    "/run/agenix/dawarich-geoapify";
  systemd.services.dawarich-sidekiq-all.serviceConfig.EnvironmentFile =
    "/run/agenix/dawarich-geoapify";
}
