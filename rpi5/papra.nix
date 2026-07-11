# Papra — document-management app (papra-hq/papra). Replaced Paperless-ngx as
# the sole document archive (bills, invoices).
#
# Papra ships as a native package + NixOS module in nixpkgs-UNSTABLE only
# (`services.papra`), so we import that module from the unstable input and pin
# the package to `unstablePkgs.papra`. The aarch64 build is cached on
# cache.nixos.org — no source compile on the Pi.
#
# Unlike every other DB-backed service here, Papra is SQLite/libSQL ONLY (no
# Postgres). So:
#   * the metadata DB lives on the SSD at /var/lib/papra/db.sqlite (StateDirectory)
#     and is backed up via a nightly sqlite `.backup` timer in backups.nix
#     (lands on /mnt/data → restic → Storj), exactly like hass / open-webui.
#   * document files live on the HDD at /mnt/data/papra/documents so restic backs
#     them up directly (restic only covers /mnt/data — see storj-backup.nix).
#
# Idle-sleep: a single papra.service (PROCESS_MODE=all → web+worker+scheduler+
# ingestion in one process) sits behind systemd-socket-proxyd (socket-activate.nix),
# waking on first request and stopping after 10 min idle. Tradeoff: scheduled
# tasks / ingestion pause while asleep and resume on wake; Better Auth sessions
# are SQLite-backed so a cold wake is safe.
{ config, lib, pkgs, inputs, tailnetFqdn, ... }:
let
  # Tailscale Serve (HTTPS :3450) → socket-activate proxy (:8220) → papra (:8221).
  externalPort = 3450;
  proxyPort    = 8220;
  backendPort  = 8221;

  appUrl = "https://${tailnetFqdn}:${toString externalPort}";

  documentsDir = "/mnt/data/papra/documents";
  ingestionDir = "/mnt/data/papra/ingestion";
in
{
  # Bring in the upstream `services.papra` module (absent from our 25.11 nixpkgs).
  # The module is self-contained (options + a single systemd unit); it evaluates
  # cleanly under our lib. If this cross-version import ever breaks, the fallback
  # is to inline its ~30-line service here using `unstablePkgs.papra`
  # (ExecStartPre = papra-migrate-up, ExecStart = papra).
  imports = [ "${inputs.nixpkgs-unstable}/nixos/modules/services/web-apps/papra.nix" ];

  services.papra = {
    enable  = true;
    # pkgs.papra resolves to unstablePkgs.papra via the overlay (overlays.nix) —
    # needs 26.6.0+ for AI auto-tagging.
    package = pkgs.papra;

    # AUTH_SECRET (Better Auth) + OPENAI_API_KEY (tiny-llm-gate) come from agenix.
    environmentFile = "/run/agenix/papra-env";

    environment = {
      # ── Networking / reverse-proxy ───────────────────────────────────────
      PORT            = backendPort;
      SERVER_HOSTNAME = "127.0.0.1";
      # Better Auth is strict about origins behind a reverse proxy. All four must
      # carry the public Tailscale Serve URL or login/cookies break.
      APP_BASE_URL    = appUrl;
      SERVER_BASE_URL = appUrl;
      CLIENT_BASE_URL = appUrl;
      TRUSTED_ORIGINS = appUrl;

      # ── Storage ──────────────────────────────────────────────────────────
      # DB stays on the SSD default (/var/lib/papra/db.sqlite); documents go to
      # the HDD so restic picks them up.
      DOCUMENT_STORAGE_FILESYSTEM_ROOT = documentsDir;

      # ── Ingestion drop-zone (migration path from Paperless) ──────────────
      # Files copied into <ingestionDir>/<organizationId>/ are ingested then
      # deleted (POST_PROCESSING default = delete). Polling watcher: robust for
      # bulk cp/rsync onto the HDD.
      INGESTION_FOLDER_IS_ENABLED          = true;
      INGESTION_FOLDER_ROOT_PATH           = ingestionDir;
      INGESTION_FOLDER_WATCHER_USE_POLLING = true;

      # ── OCR / content extraction ─────────────────────────────────────────
      # French + English. Papra takes a COMMA-separated picklist (eng,fra,deu),
      # not Paperless's "eng+fra" tesseract syntax — the config schema splits on
      # "," and validates each code against OCR_LANGUAGES.
      DOCUMENTS_OCR_LANGUAGES = "eng,fra";

      # ── AI auto-tagging via the loopback tiny-llm-gate (OpenAI-compatible) ──
      # Re-ingested docs get auto-tags (Paperless tags don't transfer — different
      # data model). Model is trivially swappable; a local model keeps document
      # content on-prem if privacy is preferred over cloud routing.
      AI_IS_ENABLED       = true;
      OPENAI_BASE_URL     = "http://127.0.0.1:4001/v1";
      # Model id must be one the gate actually serves on /v1/chat/completions
      # (NOT every id in /v1/models is routable there — e.g. gpt-5.5-mini 404s).
      # gpt-4o-mini: cheap, fast, good at the structured-output JSON the tagger
      # needs. Swap to a local gate model (e.g. openai://gemma4:e4b) if you'd
      # rather keep document content fully on-prem.
      AI_DEFAULT_MODEL    = "openai://gpt-4o-mini";
      AUTO_TAGGING_ENABLED = true;

      # First registered user becomes admin (module/app default). Registration is
      # left enabled so the account can be created on first run; tighten later.
      AUTH_FIRST_USER_AS_ADMIN = true;
    };
  };

  # Augment the upstream unit with nic-os specifics.
  systemd.services.papra = {
    serviceConfig = {
      # libSQL KV / tasks stores can write sqlite files relative to CWD; pin CWD
      # to the writable StateDirectory so they don't try to write under `/`.
      WorkingDirectory = "/var/lib/papra";
      # RPi5 boots without user-namespace support; make sure no hardening preset
      # leaves PrivateUsers=true on this unit (memory: "PrivateUsers RPi5").
      PrivateUsers = lib.mkForce false;
    };
    # Re-exec when the secret rotates.
    restartTriggers = [ config.age.secrets.papra-env.file ];
  };

  # HDD dirs owned by the papra service user (mirrors paperless consume-dir).
  # tmpfiles is a no-op if the paths already exist.
  systemd.tmpfiles.settings."10-papra" = {
    "/mnt/data/papra".d   = { user = "papra"; group = "papra"; mode = "0755"; };
    "${documentsDir}".d   = { user = "papra"; group = "papra"; mode = "0755"; };
    "${ingestionDir}".d   = { user = "papra"; group = "papra"; mode = "0755"; };
  };

  # ── Socket-activated idle sleep (rpi5/lib/socket-activate.nix) ────────────
  # Proxy on :8220 lazily starts papra.service on first connection (Tailscale
  # Serve :3450 → here) and stops it after idleSec. readyProbe gates on
  # /api/ping (always-200 public route) because the Node server binds a little
  # after systemd "active" and ExecStartPre runs migrations on cold start.
  services.socketActivate.papra = {
    enable   = true;
    realUnit = "papra.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString backendPort}";
    idleSec  = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/api/ping";
      expectStatus = 200;
      timeoutSec   = 120;
    };
  };
}
