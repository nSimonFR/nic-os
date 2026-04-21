{ pkgs, lib, redisHost, redisPort, tailnetFqdn, ... }:
let
  port = 15050;  # internal; Tailscale Serve proxies 5050 → 15050
  dataDir = "/var/lib/gramps-web";
  venvDir = "${dataDir}/venv";
  user = "gramps-web";
  group = "gramps-web";

  redisUrl = "redis://${redisHost}:${toString redisPort}/4";

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

  # Runtime tools on PATH
  runtimePath = lib.makeBinPath [
    pythonEnv
    pkgs.ffmpeg-headless
    pkgs.tesseract
    pkgs.poppler_utils
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
  # bindings from nixpkgs) and pip-installs gramps-webapi.
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
  systemd.services.gramps-web = {
    description = "Gramps Web";
    after = [ "network.target" "redis-shared.service" "gramps-web-setup.service" ];
    requires = [ "gramps-web-setup.service" ];
    wants = [ "redis-shared.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.coreutils ];
    environment = serviceEnv // {
      TMPDIR = "${dataDir}/tmp";
    };
    script = ''
      SECRET_KEY=$(cat /run/agenix/gramps-web-secret)
      export GRAMPSWEB_SECRET_KEY="$SECRET_KEY"
      exec "${venvDir}/bin/gunicorn" \
        -w 1 \
        -b 127.0.0.1:${toString port} \
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
  systemd.services.gramps-web-celery = {
    description = "Gramps Web Celery Worker";
    after = [ "network.target" "redis-shared.service" "gramps-web-setup.service" ];
    requires = [ "gramps-web-setup.service" ];
    wants = [ "redis-shared.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.coreutils ];
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
}
