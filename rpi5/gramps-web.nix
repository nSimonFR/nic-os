# gramps-web.nix — Gramps Web genealogy app (gramps-webapi + grampsjs SPA).
#
# Python venv approach: nixpkgs provides the GObject/GTK/ICU system deps, and
# gramps-webapi is pip-installed at runtime by the gramps-web-setup oneshot
# (no [ai] extras — skips PyTorch/sentence-transformers, too heavy for the RPi5).
#
# Not behind the 443 front-proxy path-mux (front-proxy.nix): Gramps Web's SPA
# hardcodes absolute API paths and its service worker needs root scope, so it
# can't be reliably served from a subpath (gramps-web#531 — closed with no
# subpath support; BASE_URL/SCRIPT_NAME workarounds break form submits + sw.js).
# Same call the repo already made for AFFiNE: keep it on its own origin. Here
# that origin is a dedicated Tailscale Serve port (5050).
#
# Socket-activated idle-sleep (rpi5/lib/socket-activate.nix): gunicorn binds
# 127.0.0.1:15051 and a proxy on 127.0.0.1:15050 (the Tailscale Serve backend
# for 5050) lazily starts gramps-web.service on the first connection, then stops
# it — plus the Celery worker (sleepWith) — after idleSec of quiet. The readyProbe
# gates the first request on /ready (unauthenticated 200) so a cold gunicorn
# (Gramps GI import is slow) doesn't drop it.
{ pkgs, lib, redisHost, redisPort, tailnetFqdn, ... }:
let
  backendPort = 15051; # real gunicorn bind (localhost only)
  proxyPort   = 15050; # socket-activate proxy listen; Tailscale Serve 5050 → here
  dataDir = "/var/lib/gramps-web";
  venvDir = "${dataDir}/venv";
  user = "gramps-web";
  group = "gramps-web";

  # Redis DB 6 — 1=immich, 2=sure, 3=dawarich, 4=paperless, 5=nextcloud are taken.
  redisUrl = "redis://${redisHost}:${toString redisPort}/6";

  # Python with GObject/GTK bindings from nixpkgs — pip can't compile these
  # from source without the system C libraries. The venv uses
  # --system-site-packages to inherit them.
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    pygobject3
    pycairo
    pillow
    pyicu
  ]);

  # GObject Introspection typelibs — Gramps core needs GTK3, GExiv2,
  # OsmGpsMap, Pango, etc. to import via `gi.require_version()`.
  # Some packages (pango, glib) default to the -bin output which has no
  # typelibs — use .out explicitly to get the girepository-1.0 directory.
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
    GRAMPSWEB_STATIC_PATH = "${dataDir}/static";
    GRAMPSWEB_THUMBNAIL_CACHE_CONFIG__CACHE_DIR = "${dataDir}/cache/thumbnails";
    GRAMPSWEB_REQUEST_CACHE_CONFIG__CACHE_DIR = "${dataDir}/cache/request_cache";
    GRAMPSWEB_PERSISTENT_CACHE_CONFIG__CACHE_DIR = "${dataDir}/cache/persistent_cache";
    GRAMPSWEB_REPORT_DIR = "${dataDir}/cache/reports";
    GRAMPSWEB_EXPORT_DIR = "${dataDir}/cache/export";
    GRAMPS_DATABASE_PATH = "${dataDir}/data/grampsdb";
    GRAMPSHOME = dataDir;
    CELERY_BROKER_URL = redisUrl;
    CELERY_RESULT_BACKEND = redisUrl;
    GUNICORN_NUM_WORKERS = "1";
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
    "d ${dataDir}/static     0750 ${user} ${group} -"
    "d ${dataDir}/tmp        0750 ${user} ${group} -"
  ];

  # ── Venv setup (oneshot) ─────────────────────────────────────────────
  # Creates a Python venv with --system-site-packages (inherits GI/GTK
  # bindings from nixpkgs) and pip-installs gramps-webapi. Runs at boot
  # (independent of the socket-activated web tier) so the venv is warm
  # before the first request — pip install is far too slow to do lazily.
  # Re-run manually: sudo systemctl start gramps-web-setup
  systemd.services.gramps-web-setup = {
    description = "Gramps Web venv setup";
    wantedBy = [ "multi-user.target" ];
    path = [ pythonEnv pkgs.coreutils ];
    environment = serviceEnv // {
      TMPDIR = "${dataDir}/tmp";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      Group = group;
      WorkingDirectory = dataDir;
      PrivateUsers = lib.mkForce false;
    };
    script = ''
      set -euo pipefail

      # Create venv if it doesn't exist
      if [ ! -f "${venvDir}/bin/python" ]; then
        echo "Creating Python venv at ${venvDir}..."
        ${pythonEnv}/bin/python3 -m venv --system-site-packages "${venvDir}"
      fi

      # Install/upgrade gramps-webapi (without AI extras)
      echo "Installing gramps-webapi..."
      "${venvDir}/bin/pip" install --upgrade --no-deps \
        'gramps-webapi' \
        'gramps[all]>=6.0.4,<6.1.0' \
        'gunicorn'

      # Install remaining deps that aren't in nixpkgs
      "${venvDir}/bin/pip" install --upgrade \
        'Flask>=2.1.0' \
        'Flask-Caching>=2.0.0' \
        'Flask-Compress' \
        'Flask-Cors' \
        'Flask-JWT-Extended>=4.2.1' \
        'Flask-Limiter>=2.9.0' \
        'Flask-SQLAlchemy' \
        'flask-smorest' \
        'marshmallow>=3.13.0' \
        'waitress' \
        'webargs' \
        'SQLAlchemy>=2.0.0' \
        'pdf2image' \
        'bleach[css]>=5.0.0' \
        'jsonschema' \
        'ffmpeg-python' \
        'boto3' \
        'alembic' \
        'celery[redis]' \
        'Unidecode' \
        'pytesseract' \
        'gramps-ql>=0.4.0' \
        'object-ql>=0.1.3' \
        'sifts>=1.1.0' \
        'requests' \
        'yclade>=0.5.0' \
        'Authlib>=1.6.4' \
        'gramps-gedcom7' \
        'typing-extensions>=4.13.0' \
        'orjson' \
        'Click>=7.0'

      # Run user DB migrations
      echo "Running user DB migrations..."
      "${venvDir}/bin/python3" -m gramps_webapi user migrate || true

      echo "Gramps Web setup complete."
    '';
  };

  # ── Gramps Web API (Gunicorn) ───────────────────────────────────────
  # No wantedBy: the socket-activate proxy on :15050 starts this on demand and
  # stops it when idle (socket-activate.nix force-clears wantedBy + adds
  # StopWhenUnneeded). Binds :15051 so the proxy can front it.
  systemd.services.gramps-web = {
    description = "Gramps Web";
    after = [ "network.target" "redis-shared.service" "gramps-web-setup.service" ];
    requires = [ "gramps-web-setup.service" ];
    wants = [ "redis-shared.service" ];
    path = [ pkgs.coreutils ] ++ runtimePkgs;
    environment = serviceEnv // {
      TMPDIR = "${dataDir}/tmp";
    };
    script = ''
      SECRET_KEY=$(cat /run/agenix/gramps-web-secret)
      export GRAMPSWEB_SECRET_KEY="$SECRET_KEY"
      exec "${venvDir}/bin/gunicorn" \
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
  # gramps-web on wake, stops alongside it on idle. No wantedBy of its own.
  systemd.services.gramps-web-celery = {
    description = "Gramps Web Celery Worker";
    after = [ "network.target" "redis-shared.service" "gramps-web-setup.service" ];
    requires = [ "gramps-web-setup.service" ];
    wants = [ "redis-shared.service" ];
    path = [ pkgs.coreutils ] ++ runtimePkgs;
    environment = serviceEnv // {
      TMPDIR = "${dataDir}/tmp";
    };
    script = ''
      SECRET_KEY=$(cat /run/agenix/gramps-web-secret)
      export GRAMPSWEB_SECRET_KEY="$SECRET_KEY"
      exec "${venvDir}/bin/celery" \
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

  # ── Socket-activated idle-sleep ──────────────────────────────────────
  # Proxy on :15050 (Tailscale Serve 5050 → here) lazily starts gramps-web on
  # first connection and stops it after idleSec. readyProbe gates on /ready
  # (unauthenticated, returns 200) because gunicorn answers slowly on a cold
  # start — Gramps' GObject-introspection import takes a few seconds — and the
  # proxy holds the first connection until the backend is actually up.
  services.socketActivate.gramps-web = {
    enable   = true;
    realUnit = "gramps-web.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString backendPort}";
    idleSec  = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/ready";
      expectStatus = 200;
      timeoutSec   = 120;
    };
    workers."gramps-web-celery.service".policy = "sleepWith";
  };
}
