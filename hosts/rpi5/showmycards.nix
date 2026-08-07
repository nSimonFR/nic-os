# hosts/rpi5/showmycards.nix
#
# ShowMyCards — self-hosted Magic: The Gathering collection manager
# (showmycards/showmycards), built from source via pkgs/services/showmycards.nix (the
# upstream image is amd64-only). Go/Fiber backend + SvelteKit (adapter-node)
# frontend, SQLite. No containers.
#
# Two processes:
#   * showmycards-backend  — Go API on 127.0.0.1:<backendPort>. Owns the SQLite
#     DB + a cache dir under DATA_DIR. Localhost-only; never Tailscale-served.
#   * showmycards-frontend — adapter-node HTTP server. Serves the UI and proxies
#     /api/* to the backend SERVER-SIDE (frontend/src/routes/api/[...path]),
#     so the browser only ever talks to the frontend — no browser CORS.
#
# ⚠ DISK: imports the full Scryfall `all_cards` feed but keeps only en + fr
#   (filter in pkgs/services/showmycards.nix) — 171158 of 535598 objects, ~0.9 GB. The DB
#   lives on /mnt/data, NEVER on / (~96% full — importing all_cards to / is what
#   filled the root fs on 2026-07-26). Widening the languages means editing that
#   filter and re-importing from a deleted DB (see below).
#
# ⚠ FIRST BOOT / bulk import: the backend AUTO-triggers the all_cards import
#   when the DB is empty (main.go: bulkDataService.TriggerInitialImport). That
#   import runs as a background job with no HTTP traffic, so the socket-activation
#   idle timer (below) would stop the service and kill it mid-stream. For the
#   one-time initial import: stop the proxy socket and run the backend directly
#   until it finishes, watching `df -h /mnt/data`:
#       sudo systemctl stop showmycards-proxy.socket showmycards-frontend
#       sudo systemctl start showmycards-backend      # import begins; watch logs + df
#   Re-enable normal idle-sleep once the DB is populated. The Scryfall refresh
#   scheduler runs in-process, so scheduled refreshes only fire while the service
#   is awake — acceptable for a personal collection tool.
#
# ⚠ A PARTIAL IMPORT IS STICKY. TriggerInitialImport is gated on HasBulkData()
#   — "any card rows at all", not "import complete" — so a half-finished import
#   makes every later start log "bulk data already exists, skipping initial
#   import" and strand you on a partial catalogue. There is no resume; retrying
#   means wiping the DB first:
#       sudo systemctl stop showmycards-proxy.socket showmycards-frontend showmycards-backend
#       sudo rm -f /mnt/data/showmycards/database.db{,-wal,-shm}
{ config, pkgs, lib, tailnetFqdn, ... }:
let
  backendPort  = 13344;  # Go API (real backend bind, localhost only)
  internalPort = 13343;  # SvelteKit node server (real frontend bind, localhost only)
  proxyPort    = 8330;   # socket-activate proxy listen; moxfield-sync writes here
  roPort       = 8331;   # nginx read-only guard; Tailscale Serve → here (see below)
  # External tailnet HTTPS port: declared once in nic.services.showmycards.public
  # below, which also derives publicUrl for `origin`.
  dataDir      = "/mnt/data/showmycards";
  origin       = config.nic.services.showmycards.public.publicUrl;
in
{
  users.users.showmycards = {
    isSystemUser = true;
    group = "showmycards";
    description = "ShowMyCards service user";
  };
  users.groups.showmycards = { };

  # DB + data cache on /mnt/data (see disk note above).
  systemd.tmpfiles.rules = [
    "d ${dataDir}      0750 showmycards showmycards - -"
    "d ${dataDir}/data 0750 showmycards showmycards - -"
  ];

  # Machine-readable API contract for the `showmycards` agent skill. There is no
  # OpenAPI spec (upstream's DEVELOPMENT.md claims /swagger; it 404s), so the
  # tygo-generated TS types are the authoritative shapes — they carry every
  # request/response interface plus the limits (MaxBatchIDs, MaxBatchItems,
  # CurrentExportVersion). Pinning them to a stable path means the skill points
  # at generated truth and follows the package on every version bump, instead of
  # embedding a prose snapshot that silently drifts.
  environment.etc."showmycards/api/api.ts".source =
    "${pkgs.showmycards}/share/showmycards/api/api.ts";
  environment.etc."showmycards/api/models.ts".source =
    "${pkgs.showmycards}/share/showmycards/api/models.ts";

  # ── Go backend ─────────────────────────────────────────────────────────────
  # No wantedBy here — the socketActivate `workers` block below binds this to the
  # frontend's lifecycle (sleepWith → wantedBy + partOf = frontend), so it starts
  # when the frontend wakes and idle-stops with it. Both processes reach ~0 RAM
  # at rest.
  systemd.services.showmycards-backend = {
    description = "ShowMyCards backend (Go/Fiber API, SQLite)";
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];
    environment = {
      PORT            = toString backendPort;
      DATABASE_PATH   = "${dataDir}/database.db";
      DATA_DIR        = "${dataDir}/data";
      ALLOWED_ORIGINS = origin;
      LOG_LEVEL       = "info";
      # GODEBUG=http2client=0 is baked into the package wrapper (see
      # pkgs/services/showmycards.nix) so the streamed all_cards import doesn't fail.
    };
    serviceConfig = {
      ExecStart = "${pkgs.showmycards}/bin/showmycards-backend";
      User      = "showmycards";
      Group     = "showmycards";
      Restart   = "on-failure";
      RestartSec = 5;
    };
  };

  # ── SvelteKit frontend (adapter-node) — the socket-activated realUnit ──────
  # Backend coupling is handled by the socketActivate `workers` block (the
  # backend is wantedBy this unit), and the readyProbe gates traffic until the
  # backend is reachable through the proxy — so no explicit wants/after here.
  systemd.services.showmycards-frontend = {
    description = "ShowMyCards frontend (SvelteKit adapter-node)";
    environment = {
      HOST               = "127.0.0.1";
      PORT               = toString internalPort;
      ORIGIN             = origin;  # adapter-node CSRF origin (else form POSTs 403)
      PUBLIC_BACKEND_URL = "http://127.0.0.1:${toString backendPort}";  # $env/dynamic/public, runtime
    };
    serviceConfig = {
      ExecStart = "${pkgs.showmycards}/bin/showmycards-frontend";
      User      = "showmycards";
      Group     = "showmycards";
      Restart   = "on-failure";
      RestartSec = 5;
    };
  };

  # ── Read-only guard for the tailnet (nginx) ────────────────────────────────
  # ShowMyCards has NO authentication of any kind — no token, no session, every
  # write unguarded — and since moxfield-sync.nix made Moxfield the single writer,
  # anything edited in this UI is silently reverted on the next daily sync. Better
  # to refuse the edit than to accept it and throw it away overnight.
  #
  # The filter sits in FRONT of the socket-activate proxy rather than on it, because
  # :8330 is also how moxfield-sync writes. Tailscale Serve points at this vhost
  # (nic.services.showmycards.public.backend), so browsers get read-only while the sync — which
  # talks to 127.0.0.1:8330 directly, and is not reachable from the tailnet — keeps
  # full access. Read-only is therefore a property of the ROUTE, not the service.
  services.nginx.virtualHosts."showmycards-ro" = {
    listen = [ { addr = "127.0.0.1"; port = roPort; ssl = false; } ];
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString proxyPort}";
      proxyWebsockets = true;
      extraConfig = ''
        # GET/HEAD/OPTIONS through, everything mutating refused. This covers both
        # the SvelteKit /api/* passthrough and its form actions, since both are
        # POST/PUT/PATCH/DELETE from the browser's point of view.
        limit_except GET HEAD OPTIONS { deny all; }

        # A cold wake runs the socket-activate readyProbe, which is allowed up to
        # 60s (see below). nginx's 60s defaults would 504 at exactly the wrong
        # moment — the first visit after idle — so give the chain room.
        proxy_connect_timeout 75s;
        proxy_read_timeout    120s;
        proxy_send_timeout    120s;
      '';
    };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ─────────────
  # Proxy on :8330 lazily starts the frontend on first connection and idle-stops
  # it after idleSec. The backend is declared as a `sleepWith` worker so it
  # starts and stops in lock-step with the frontend (both → ~0 RAM at rest).
  # readyProbe hits /api/health THROUGH the frontend proxy, so a wake only
  # reports ready once the whole chain (frontend + backend) is up. See the FIRST
  # BOOT note above before the initial import.
  services.socketActivate.showmycards = {
    enable   = true;
    realUnit = "showmycards-frontend.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString internalPort}";
    idleSec  = 600;
    # Backend sleeps alongside the frontend (wantedBy + partOf = frontend).
    workers."showmycards-backend.service".policy = "sleepWith";
    readyProbe = {
      url          = "http://127.0.0.1:${toString internalPort}/api/health";
      expectStatus = 200;
      timeoutSec   = 60;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  # database.db and the Scryfall cache both live under /mnt/data/showmycards,
  # so restic covers them with no dump step. The units were missing from the
  # heavy list, so a rebuild left the SvelteKit frontend and the Go backend
  # resident — fixed by declaring them here.
  nic.services.showmycards = {
    backup        = [ "mnt-data" ];
    heavyUnits    = [ "showmycards-frontend.service" "showmycards-backend.service" ];
    heavyPriority = 155;

    # backend is :8331 (the nginx read-only guard), NOT :8330 (the socket-activate
    # proxy): Moxfield is the single writer, so an edit made through the tailnet
    # would be reverted by the next daily sync. moxfield-sync itself still writes
    # via :8330, which the tailnet cannot reach.
    public = {
      order   = 190;
      port    = 3550;
      backend = "http://127.0.0.1:8331";
      tile = {
        name        = "ShowMyCards";
        icon        = "mdi-cards-playing-outline";
        category    = "Apps";
        description = "Magic: The Gathering collection";
        # Reads ShowMyCards' SQLite directly rather than its HTTP API: :8330 is the
        # only thing that wakes the service, so an API-backed widget would pin it
        # awake permanently.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/showmycards";
          refreshInterval = 3600000;
          # "value" is EUR, computed foil-aware from the Scryfall prices in the local
          # catalogue (which self-updates daily at 03:00) — NOT ShowMyCards' own
          # total_collection_value, which is a different currency or blend and could
          # not be reproduced.
          mappings = [
            { field = "cards"; label = "Cards"; format = "number"; }
            { field = "decks"; label = "Decks"; format = "number"; }
            { field = "value"; label = "Value"; format = "float"; prefix = "€"; }
          ];
        };
      };
    };
  };
}
