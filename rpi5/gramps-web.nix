# gramps-web.nix — Gramps Web genealogy app (gramps-web-api + grampsjs SPA).
#
# Native packages (no runtime pip): the API, the grampsjs frontend and their
# Python deps are built from the derivations vendored in ./pkgs/gramps-web
# (nixpkgs PR #417806, rebased onto our 25.11 — see that overlay for why it's
# vendored rather than used as a flake input, and which upstream bits are cut).
#   * pkgs.python3Packages.gramps-web-api — the WSGI/Celery backend
#   * pkgs.gramps-web                      — the built SPA (→ .../static)
#
# Not behind the 443 front-proxy path-mux (front-proxy.nix): Gramps Web's SPA
# hardcodes absolute API paths and its service worker needs root scope, so it
# can't be reliably served from a subpath (gramps-web#531 — closed with no
# subpath support; BASE_URL/SCRIPT_NAME workarounds break form submits + sw.js).
# Same call the repo already made for AFFiNE: keep it on its own origin. Here
# that origin is a dedicated Tailscale Serve port (5050).
#
# Socket-activated lazy-start (rpi5/lib/socket-activate.nix): gunicorn binds
# 127.0.0.1:15051 and a proxy on 127.0.0.1:15050 (the Tailscale Serve backend
# for 5050) lazily starts gramps-web.service — plus the Celery worker
# (sleepWith) — on the first connection. idleSec = null: no idle-stop, the units
# stay warm once woken (avoids cold-wake latency on every use). The readyProbe
# gates the first request on /ready (unauthenticated 200) so a cold gunicorn
# (Gramps GI import is slow) doesn't drop it.
{ pkgs, lib, redisHost, redisPort, tailnetFqdn, ... }:
let
  backendPort = 15051; # real gunicorn bind (localhost only)
  proxyPort   = 15050; # socket-activate proxy listen; Tailscale Serve 5050 → here
  dataDir = "/var/lib/gramps-web";
  user = "gramps-web";
  group = "gramps-web";

  # Redis DB 6 — 1=immich, 2=sure, 3=dawarich, 4=paperless, 5=nextcloud are taken.
  redisUrl = "redis://${redisHost}:${toString redisPort}/6";

  # Runtime Python env: the native gramps-web-api (pulls in gramps, celery,
  # flask, sqlalchemy, …) plus gunicorn to serve it. gramps_webapi is importable
  # and the celery/gunicorn console scripts land on the env's bin/.
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.gramps-web-api
    ps.gunicorn
    ps.celery
  ]);

  # GObject Introspection typelibs — Gramps needs GTK3, GExiv2, OsmGpsMap,
  # Pango, etc. at `gi.require_version()` time. gramps-web-api itself is built
  # with wrapGAppsHook3, but we launch it via gunicorn from the env above (not
  # its wrapped entry point), so GI_TYPELIB_PATH must be set on the service.
  # pango/glib default to their -bin output which has no typelibs → use .out.
  typelibPkgs = with pkgs; [
    gobject-introspection  # cairo, DBus, fontconfig, freetype2
    at-spi2-core           # Atk, Atspi (required by GTK3)
    gtk3
    glib.out               # GLib, GObject, Gio, GModule
    pango.out              # Pango, PangoCairo, PangoFT2
    gdk-pixbuf
    gexiv2
    osm-gps-map
    harfbuzz
  ];

  giTypelibPath = lib.concatMapStringsSep ":" (p:
    "${p}/lib/girepository-1.0"
  ) typelibPkgs;

  # Runtime tools Celery shells out to (thumbnails, OCR, report/media export).
  runtimePkgs = [
    pkgs.ffmpeg-headless
    pkgs.tesseract
    pkgs.poppler-utils
    pkgs.graphviz
    pkgs.ghostscript
  ];

  # Shared environment for both gunicorn and celery
  serviceEnv = {
    GRAMPSWEB_TREE = "Family Tree";
    GRAMPSWEB_BASE_URL = "https://${tailnetFqdn}:5050";
    GRAMPSWEB_USER_DB_URI = "sqlite:///${dataDir}/data/users.sqlite";
    GRAMPSWEB_SEARCH_INDEX_DB_URI = "sqlite:///${dataDir}/indexdir/search_index.db";
    GRAMPSWEB_MEDIA_BASE_DIR = "${dataDir}/media";
    # Frontend static assets come straight from the nix store (the missing piece
    # of the old pip approach — index.html + sw.js live here).
    GRAMPSWEB_STATIC_PATH = "${pkgs.gramps-web}/share/gramps-web/static";
    GRAMPSWEB_THUMBNAIL_CACHE_CONFIG__CACHE_DIR = "${dataDir}/cache/thumbnails";
    GRAMPSWEB_REQUEST_CACHE_CONFIG__CACHE_DIR = "${dataDir}/cache/request_cache";
    GRAMPSWEB_PERSISTENT_CACHE_CONFIG__CACHE_DIR = "${dataDir}/cache/persistent_cache";
    GRAMPSWEB_REPORT_DIR = "${dataDir}/cache/reports";
    GRAMPSWEB_EXPORT_DIR = "${dataDir}/cache/export";
    GRAMPS_DATABASE_PATH = "${dataDir}/data/grampsdb";
    GRAMPSHOME = dataDir;
    CELERY_BROKER_URL = redisUrl;
    CELERY_RESULT_BACKEND = redisUrl;
    GI_TYPELIB_PATH = giTypelibPath;
    # Limit thread usage for RPi5
    OMP_NUM_THREADS = "1";
  };

  commonServiceConfig = {
    User = user;
    Group = group;
    WorkingDirectory = dataDir;
    Restart = "on-failure";
    RestartSec = "5s";
    PrivateUsers = lib.mkForce false;  # RPi5 kernel: no user namespaces
  };
in
{
  # ── System user ──────────────────────────────────────────────────────
  users.users.${user} = {
    isSystemUser = true;
    inherit group;
    home = dataDir;
  };
  users.groups.${group} = { };

  # ── Data directories ─────────────────────────────────────────────────
  # (No venv/static dir anymore — code + frontend live in the nix store.)
  systemd.tmpfiles.rules = [
    "d ${dataDir}            0750 ${user} ${group} -"
    "d ${dataDir}/data       0750 ${user} ${group} -"
    "d ${dataDir}/data/grampsdb 0750 ${user} ${group} -"
    "d ${dataDir}/media      0750 ${user} ${group} -"
    "d ${dataDir}/indexdir   0750 ${user} ${group} -"
    "d ${dataDir}/cache      0750 ${user} ${group} -"
    "d ${dataDir}/cache/thumbnails    0750 ${user} ${group} -"
    "d ${dataDir}/cache/request_cache 0750 ${user} ${group} -"
    "d ${dataDir}/cache/persistent_cache 0750 ${user} ${group} -"
    "d ${dataDir}/cache/reports  0750 ${user} ${group} -"
    "d ${dataDir}/cache/export   0750 ${user} ${group} -"
    "d ${dataDir}/tmp        0750 ${user} ${group} -"
  ];

  # ── Gramps Web API (Gunicorn) ───────────────────────────────────────
  # No wantedBy: the socket-activate proxy on :15050 starts this on demand
  # (socket-activate.nix force-clears wantedBy). idleSec = null → no idle-stop,
  # so it stays up once woken. Binds :15051 so the proxy can front it.
  systemd.services.gramps-web = {
    description = "Gramps Web";
    after = [ "network.target" "redis-shared.service" ];
    wants = [ "redis-shared.service" ];
    path = [ pkgs.coreutils ] ++ runtimePkgs;
    environment = serviceEnv // {
      TMPDIR = "${dataDir}/tmp";
    };
    script = ''
      SECRET_KEY=$(cat /run/agenix/gramps-web-secret)
      export GRAMPSWEB_SECRET_KEY="$SECRET_KEY"
      # Idempotent user-DB migration (was the old pip setup oneshot's job).
      ${pythonEnv}/bin/python3 -m gramps_webapi user migrate || true
      exec "${pythonEnv}/bin/gunicorn" \
        -w 1 \
        -b 127.0.0.1:${toString backendPort} \
        --timeout 120 \
        --limit-request-line 8190 \
        gramps_webapi.wsgi:app
    '';
    serviceConfig = commonServiceConfig // {
      Type = "simple";
      MemoryMax = "384M";
      SupplementaryGroups = [ ];
    };
  };

  # ── Celery worker (thumbnails, search indexing, exports) ─────────────
  # sleepWith the web tier (see socketActivate.workers below): starts alongside
  # gramps-web on wake (partOf, so it also stops if gramps-web ever stops). No
  # wantedBy of its own.
  systemd.services.gramps-web-celery = {
    description = "Gramps Web Celery Worker";
    after = [ "network.target" "redis-shared.service" ];
    wants = [ "redis-shared.service" ];
    path = [ pkgs.coreutils ] ++ runtimePkgs;
    environment = serviceEnv // {
      TMPDIR = "${dataDir}/tmp";
    };
    script = ''
      SECRET_KEY=$(cat /run/agenix/gramps-web-secret)
      export GRAMPSWEB_SECRET_KEY="$SECRET_KEY"
      exec "${pythonEnv}/bin/celery" \
        -A gramps_webapi.celery \
        worker \
        --loglevel=info \
        --concurrency=1
    '';
    serviceConfig = commonServiceConfig // {
      Type = "simple";
      RestartSec = "10s";
      MemoryMax = "256M";
    };
  };

  # ── Socket-activated lazy-start ──────────────────────────────────────
  # Proxy on :15050 (Tailscale Serve 5050 → here) lazily starts gramps-web on
  # the first connection. idleSec = null → lazy-start only, no idle-stop: the
  # web + celery units stay warm once woken. readyProbe gates on /ready
  # (unauthenticated, returns 200) because gunicorn answers slowly on a cold
  # start — Gramps' GObject-introspection import takes a few seconds — and the
  # proxy holds the first connection until the backend is actually up.
  services.socketActivate.gramps-web = {
    enable   = true;
    realUnit = "gramps-web.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString backendPort}";
    idleSec  = null;  # ignore idle — lazy-start only, stays up once warm
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/ready";
      expectStatus = 200;
      timeoutSec   = 120;
    };
    workers."gramps-web-celery.service".policy = "sleepWith";
  };
}
