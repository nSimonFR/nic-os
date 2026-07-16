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
{ config, lib, pkgs, inputs, tailnetFqdn, pgHost, pgPort, ... }:
let
  # Tailscale Serve (HTTPS :3450) → socket-activate proxy (:8220) → papra (:8221).
  externalPort = 3450;
  proxyPort    = 8220;
  backendPort  = 8221;

  appUrl = "https://${tailnetFqdn}:${toString externalPort}";

  documentsDir = "/mnt/data/papra/documents";
  ingestionDir = "/mnt/data/papra/ingestion";

  # Personal org ("Nico's organization") — auto-ingest target for the feeders.
  personalOrg = "org_g9brest62431f0c6w3uywbdr";
  # Top-level Nextcloud "PAPRA" folder (drive drop-zone; also the Proton poller's
  # ingestion target). Matches the user's ALL-CAPS top-level folder convention.
  ncInbox = "/mnt/data/nextcloud/data/nsimon/files/PAPRA";
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

      # ── AI auto-tagging: Papra-native, routed on-prem to beast ────────────
      # Papra's built-in auto-tagger runs on ingest, via the loopback gate. The
      # model is the beast-only qwen3-vl:8b entry (NO cloud fallback in the gate),
      # so OCR'd content never leaves the network — a beast-down request errors
      # rather than routing to a cloud model. qwen3-vl:8b respects the strict
      # json_schema Papra's tagger requires and tags well in French.
      # NOTE: native tagging is fire-once with no retry — a doc ingested while
      # beast is asleep/down stays untagged until re-ingested (no wait-for-beast).
      AI_IS_ENABLED        = true;
      OPENAI_BASE_URL      = "http://127.0.0.1:4001/v1";
      AI_DEFAULT_MODEL     = "openai://qwen3-vl:8b";
      AUTO_TAGGING_ENABLED = true;

      # Allow webhook delivery to the loopback tag-sync receiver (Papra's SSRF
      # guard blocks 127.0.0.1 by default).
      WEBHOOK_URL_ALLOWED_HOSTNAMES = "127.0.0.1";

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

  # ── Nextcloud "PAPRA" inbox feeder ────────────────────────────────────────
  # Files dropped into the Nextcloud PAPRA folder are copied into Papra's
  # ingestion drop-zone; Papra ingests them and its native auto-tagger tags them.
  # Originals are left in place (see script header). Runs as root to bridge the
  # nextcloud-owned source files → papra-owned ingestion dir.
  systemd.services.papra-inbox-watch = {
    description = "Feed the Nextcloud PAPRA folder into Papra ingestion";
    path = with pkgs; [ coreutils findutils gnugrep ];
    environment = {
      PAPRA_INBOXES    = ncInbox;
      PAPRA_INBOX_DEST = "${ingestionDir}/${personalOrg}";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${pkgs.bash}/bin/bash ${./scripts/papra-inbox-watch.sh}";
      StateDirectory = "papra-inbox-watch";
    };
  };
  systemd.timers.papra-inbox-watch = {
    description = "Poll the Nextcloud PAPRA folder";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "3min";
      OnUnitActiveSec = "2min";
      Persistent      = true;
    };
  };

  # ── Tagging safety-net: reconcile any UNTAGGED docs (waits for beast) ─────
  # Papra's native auto-tagger is fire-once with no retry, so a doc ingested
  # while beast was asleep/down stays untagged. This sweeps untagged docs on-prem
  # (beast-only qwen3-vl:8b) every 15 min; it aborts + retries next run when beast
  # is unreachable, so the backlog is tagged once beast returns. Runs as papra.
  systemd.services.papra-tag-sweep = {
    description = "Papra tagging safety-net (reconcile untagged docs)";
    serviceConfig = {
      Type = "oneshot";
      User = "papra";
      Group = "papra";
      WorkingDirectory = "/var/lib/papra";
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/papra-tag-sweep.py}";
    };
  };
  systemd.timers.papra-tag-sweep = {
    description = "Periodic Papra untagged-doc reconcile";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "6min";
      OnUnitActiveSec = "15min";
      Persistent      = true;
    };
  };

  # ── Proton Mail feeder (via the existing hydroxide bridge) ────────────────
  # Polls the Proton "Papra" folder over hydroxide IMAP (:1143) and drops
  # document attachments (PDF/images, skips .ics) into Papra's ingestion
  # drop-zone. Processed messages tracked by Message-ID (mailbox never mutated).
  # Runs as root: reads the hydroxide-group bridge password + writes the
  # papra-owned ingestion dir. File a bill into the Proton "Papra" folder and it
  # lands in Papra within a few minutes.
  systemd.services.papra-proton-poll = {
    description = "Feed Proton 'Papra' folder attachments into Papra ingestion";
    after = [ "hydroxide.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.python3 ];
    environment.PAPRA_PROTON_DEST = "${ingestionDir}/${personalOrg}";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/papra-proton-poll.py}";
      StateDirectory = "papra-proton-poll";
    };
  };
  systemd.timers.papra-proton-poll = {
    description = "Poll Proton 'Papra' folder";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec       = "4min";
      OnUnitActiveSec = "5min";
      Persistent      = true;
    };
  };

  # ── Papra → Nextcloud tag sync (webhook receiver) ─────────────────────────
  # Papra fires an HMAC-signed webhook on document.tags.changed; this receiver
  # (127.0.0.1:8347) verifies it, reads the doc's current tags from Papra's
  # SQLite, matches the file in Nextcloud by original filename, and mirrors the
  # tags as Nextcloud systemtags (writes oc_systemtag[_object_mapping] in PG as
  # nextcloud_user; DB password read from Nextcloud's config.php). Docs with no
  # Nextcloud counterpart (e.g. Proton-sourced) are skipped. Register the webhook
  # in Papra pointing at this URL with the papra-webhook-secret.
  systemd.services.papra-webhook-tagsync = {
    description = "Papra -> Nextcloud tag sync (webhook receiver)";
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql.service" "network.target" ];
    environment = {
      LISTEN_ADDR = "127.0.0.1";
      LISTEN_PORT = "8347";
      PAPRA_DB = "/var/lib/papra/db.sqlite";
      PAPRA_WEBHOOK_SECRET_FILE = "/run/agenix/papra-webhook-secret";
      NC_PG_HOST = pgHost;
      NC_PG_PORT = toString pgPort;
      NC_PG_DB = "nextcloud_production";
      NC_PG_USER = "nextcloud_user";
      NC_CONFIG = "/mnt/data/nextcloud/config/config.php";
      NC_USER = "nsimon";
    };
    serviceConfig = {
      User = "nextcloud";
      Group = "nextcloud";
      ExecStart = "${pkgs.python3.withPackages (ps: [ ps.psycopg2 ])}/bin/python3 ${./scripts/papra-webhook-tagsync.py}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Idempotently (re)register the Papra webhook that drives the tag-sync receiver.
  # Papra keeps webhooks as DB rows, so this reconciles them on every activation —
  # surviving a Papra DB reset and picking up a rotated papra-webhook-secret.
  systemd.services.papra-webhook-register = {
    description = "Register the Papra -> Nextcloud tag-sync webhook";
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ sqlite coreutils ];
    environment = {
      PAPRA_DB = "/var/lib/papra/db.sqlite";
      PAPRA_ORG = personalOrg;
      PAPRA_WEBHOOK_URL = "http://127.0.0.1:8347/";
      PAPRA_WEBHOOK_SECRET_FILE = "/run/agenix/papra-webhook-secret";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${pkgs.bash}/bin/bash ${./scripts/papra-webhook-register.sh}";
    };
    restartTriggers = [ config.age.secrets.papra-webhook-secret.file ];
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
