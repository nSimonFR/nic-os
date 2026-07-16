# plane.nix — host wiring for Plane (OSS Jira/Linear alternative).
#
# The package + base service tier live in the plane-nix flake
# (nixosModules.plane, imported in flake.nix) — same split as sure-nix /
# gramps-web-nix. This file does the nic-os-specific bits: PostgreSQL role,
# Redis DB index, agenix EnvironmentFile, Storj S3 attachments, a dedicated
# Tailscale Serve port, and socket-activated idle-sleep for the RAM-tight rpi5.
#
# Origin: like AFFiNE / Gramps Web, Plane's React-Router SPAs (web at /, space
# at /spaces, admin at /god-mode) need a root origin — they can't live under a
# 443 path-mux subpath. So Plane gets its own Serve port (3800, see
# services-registry.nix), fronting the always-on nginx vhost from the module.
#
# Idle-sleep (rpi5/lib/socket-activate.nix): the module's nginx vhost is always
# up (≈0 RAM — static files), but proxies /api,/auth,/static to a socket-proxy
# port that lazy-wakes plane-api. worker + beat + live are `sleepWith` so the
# whole heavy tier (~1 GB active) stops together after idleSec and the first
# page-load /api call wakes it (~10-20 s cold start). beat sleeps too — accepted
# for a personal instance (scheduled sweeps skip while idle); flip it to
# keepAwake if you rely on Plane's periodic automations.
#
# STATUS: derivation-evaluation only. Not yet rebuilt onto the live system
# (per the eval-only directive). Deploy-time TODOs: mint a scoped Storj S3
# credential for the plane-attachments bucket, fill the agenix secrets with
# real values, and verify the readyProbe path + live start.mjs runtime deps.
{ config, pkgs, lib, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, ... }:
let
  servePort   = 3800;  # Tailscale Serve → nginx vhost (always-on static tier)
  nginxPort   = 8330;  # module nginx vhost bind (Serve backend)
  apiProxyPort = 8331; # socket-activate proxy listen; nginx /api → here
  apiPort     = 8332;  # gunicorn ASGI bind (behind the proxy)
  livePort    = 8333;  # Hocuspocus WS bind
  baseUrl     = "https://${tailnetFqdn}:${toString servePort}";
in
{
  # ── Plane service tier (native, via plane-nix flake) ──────────────────────
  services.plane = {
    enable      = true;
    host        = "127.0.0.1";
    port        = nginxPort;
    inherit apiPort livePort;
    # nginx proxies /api,/auth,/static through the socket-activation proxy so the
    # first request wakes the idle-slept api group. /live goes straight to the
    # live bind (it's woken as part of the same group — see socketActivate below).
    apiUpstream  = "127.0.0.1:${toString apiProxyPort}";
    liveUpstream = "127.0.0.1:${toString livePort}";
    inherit baseUrl;
    # Redis DB 7 — 1=immich 2=sure 3=dawarich 5=nextcloud 6=gramps taken (0=default, 4 freed).
    redisUrl    = "redis://${redisHost}:${toString redisPort}/7";
    # Plane's Celery broker is AMQP-only: settings.common derives CELERY_BROKER_URL
    # from AMQP_URL, else defaults to amqp://guest@localhost:5672 (RabbitMQ). We run
    # no RabbitMQ, so point Celery at Redis (kombu redis transport) on a dedicated
    # DB (8, separate from the DB-7 cache). Without it every bg task — incl.
    # workspace_seed.delay() — dies "Connection refused", so workspace creation → 500.
    extraEnv = {
      AMQP_URL = "redis://${redisHost}:${toString redisPort}/8";
    };
    secretsFile = "/run/agenix/plane-app-env";
    gunicornWorkers = 1;  # bound RSS on the 4 GB rpi5
    s3 = {
      endpointUrl = "https://gateway.storjshare.io";
      bucket      = "plane-attachments";  # TODO deploy: create bucket + scoped S3 creds
      region      = "";
    };
  };

  # ── PostgreSQL: plane database + plane user ───────────────────────────────
  services.postgresql = {
    ensureDatabases = [ "plane" ];
    ensureUsers = [{
      name = "plane";
      # ownership granted in plane-pg-setup (ensureDBOwnership needs db==user; it is here,
      # but we still set the password + owner explicitly like the other services).
    }];
    authentication = lib.mkAfter ''
      host  plane  plane  ${pgHost}/32  scram-sha-256
    '';
  };

  # Set the plane role password + DB ownership from the agenix secret (no
  # ensurePasswordFile in 25.11). Ordered After postgresql-setup so ensureUsers
  # has created the role before the ALTER (first-boot race — see sure-pg-setup).
  systemd.services.plane-pg-setup = {
    description = "Set plane PostgreSQL role password";
    after    = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      password=$(cat /run/agenix/plane-pg-password)
      ${pkgs.postgresql}/bin/psql -v pw="$password" <<< "ALTER USER plane WITH PASSWORD :'pw';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE plane OWNER TO plane;"
    '';
  };

  # plane-migrate must wait for the role password to be set (it connects via the
  # DATABASE_URL in plane-app-env) and for Redis.
  systemd.services.plane-migrate = {
    after    = [ "plane-pg-setup.service" "redis-shared.service" ];
    requires = [ "plane-pg-setup.service" ];
    wants    = [ "redis-shared.service" ];
  };
  systemd.services.plane-worker.after = [ "redis-shared.service" ];
  systemd.services.plane-worker.wants = [ "redis-shared.service" ];
  systemd.services.plane-beat.after   = [ "redis-shared.service" ];
  systemd.services.plane-beat.wants   = [ "redis-shared.service" ];

  # ── Socket-activated idle-sleep (rpi5/lib/socket-activate.nix) ────────────
  # plane-api is the heaviest tier; Django/uvicorn cold start is slow, so a
  # readyProbe gates the first proxied request. worker+beat+live are sleepWith
  # → the whole group stops together when the api idle-stops, and wakes together
  # on the first /api call the SPA makes on page load.
  services.socketActivate.plane = {
    enable    = true;
    realUnit  = "plane-api.service";
    listen    = [ "127.0.0.1:${toString apiProxyPort}" ];
    backend   = "127.0.0.1:${toString apiPort}";
    idleSec   = 600;
    readyProbe = {
      # /api/instances/ returns the instance config unauthenticated (200) once
      # the ASGI app is serving. TODO verify this path against the pinned Plane.
      url          = "http://127.0.0.1:${toString apiPort}/api/instances/";
      expectStatus = 200;
      timeoutSec   = 120;
    };
    workers = {
      "plane-worker.service".policy = "sleepWith";
      "plane-beat.service".policy   = "sleepWith";
      "plane-live.service".policy   = "sleepWith";
    };
  };

  # ── RAM hygiene ───────────────────────────────────────────────────────────
  # No user namespaces on the rpi5 kernel → force PrivateUsers off (mirrors
  # affine/sure). Cap RSS so a runaway worker can't OOM-thrash the box.
  systemd.services.plane-api.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    MemoryHigh = "700M";
    MemoryMax  = "900M";
  };
  systemd.services.plane-worker.serviceConfig = {
    PrivateUsers = lib.mkForce false;
    MemoryHigh = "400M";
    MemoryMax  = "550M";
  };
  systemd.services.plane-beat.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.plane-migrate.serviceConfig.PrivateUsers = lib.mkForce false;
}
