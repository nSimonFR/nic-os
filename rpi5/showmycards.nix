# rpi5/showmycards.nix
#
# ShowMyCards — self-hosted Magic: The Gathering collection manager
# (showmycards/showmycards), built from source via pkgs/showmycards.nix (the
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
# ⚠ DISK: user chose the full Scryfall `all_cards` dataset (~multi-GB). The DB
#   therefore lives on /mnt/data (594 GB free), NEVER on / (~89% full — importing
#   all_cards to / is exactly what filled the root fs on 2026-07-26).
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
{ config, pkgs, lib, tailnetFqdn, ... }:
let
  backendPort  = 13344;  # Go API (real backend bind, localhost only)
  internalPort = 13343;  # SvelteKit node server (real frontend bind, localhost only)
  proxyPort    = 8330;   # socket-activate proxy listen; Tailscale Serve → here
  servePort    = 3550;   # external tailnet HTTPS port (see services-registry.nix)
  dataDir      = "/mnt/data/showmycards";
  origin       = "https://${tailnetFqdn}:${toString servePort}";
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
      # pkgs/showmycards.nix) so the streamed all_cards import doesn't fail.
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

  # ── Socket-activated idle sleep (rpi5/lib/socket-activate.nix) ─────────────
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
}
