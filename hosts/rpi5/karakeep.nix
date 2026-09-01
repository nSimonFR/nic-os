# hosts/rpi5/karakeep.nix
#
# Karakeep (ex-Hoarder) — AI-tagged bookmark / read-later app. Native nixpkgs
# 25.11 `services.karakeep` module: builds for aarch64, stores everything in
# SQLite under /var/lib/karakeep (no Postgres setup), and auto-manages its own
# Meilisearch instance for full-text search.
#
# AI auto-tagging/summaries run through tiny-llm-gate → beast Ollama (local,
# zero external cost). No agenix secret: karakeep-init generates MEILI_MASTER_KEY
# + NEXTAUTH_SECRET into /var/lib/karakeep/settings.env on first boot.
#
# Memory-constrained RPi5: the stack (web + workers + Meilisearch) sleeps after
# 10 min idle via the socket-activation pattern (hosts/rpi5/lib/socket-activate.nix,
# same as papra), returning to ~0 RAM at rest.
#
# Local headless Chromium (screenshots + full-page archival) is DISABLED: nixpkgs
# has no cached aarch64 build at our pinned rev, so browser.enable = true would
# compile Chromium from source on the Pi (multi-hour, OOM-thrash risk). Karakeep
# keeps link crawling, readable-text extraction, favicons, AI tagging/summaries,
# embeddings and full-text search without it. To restore screenshots later,
# offload the browser to beast (x86_64, cached) and set BROWSER_WEB_URL.
{ config, pkgs, lib, tailnetFqdn, tinyLlmGateUrl, ... }:
let
  webPort   = 13200;   # karakeep-web PORT (real backend bind)
  proxyPort = 8210;    # socket-activate proxy listen; Tailscale Serve points here
  # External tailnet HTTPS port: declared once in nic.services.karakeep.public
  # below, which also derives publicUrl for NEXTAUTH_URL.
in
{
  services.karakeep = {
    enable = true;
    browser.enable = false;      # local Chromium disabled — no cached aarch64 build (see header)
    meilisearch.enable = true;   # auto-enables services.meilisearch (:7700, dev/keyless on localhost)

    extraEnvironment = {
      PORT = toString webPort;

      # Bind localhost only (Next.js honours HOSTNAME). The only tailnet ingress
      # is the socket-activate proxy → Tailscale Serve; :13200 must never be
      # reachable directly on the tailnet interface.
      HOSTNAME = "127.0.0.1";

      # Public URL behind the Tailscale Serve proxy — used for NextAuth callbacks.
      NEXTAUTH_URL = config.nic.services.karakeep.public.publicUrl;

      DISABLE_NEW_RELEASE_CHECK = "true";

      # Admin account is set up, so lock down public registration: no new
      # signups and the signup button is hidden in the UI. Existing users
      # (us) can still sign in. NOT DISABLE_PASSWORD_AUTH — that would disable
      # the local login form entirely, and no OAuth provider is configured.
      DISABLE_SIGNUPS = "true";

      # ── AI auto-tagging via local inference (tiny-llm-gate → beast Ollama) ──
      OPENAI_API_KEY  = "ollama";                       # value ignored by tiny-llm-gate
      OPENAI_BASE_URL = "${tinyLlmGateUrl}/v1";          # http://127.0.0.1:4001/v1
      INFERENCE_TEXT_MODEL  = "gemma4:e4b";              # text tagging/summaries on beast
      INFERENCE_IMAGE_MODEL = "gemma4:e4b";              # image tagging (drop if not multimodal)
      EMBEDDING_TEXT_MODEL  = "text-embedding-3-small";  # → qwen3-embedding:8b via gate alias
    };
  };

  # No PrivateUsers override needed: the only karakeep unit that sets
  # PrivateUsers=true is karakeep-browser, which we don't enable. The remaining
  # units (karakeep-init/-workers/-web) run as the static `karakeep` user with
  # PrivateTmp only, which works fine on the RPi5 (no user namespaces).

  # Order the search backend ahead of the consumers so a cold wake doesn't hit
  # Meilisearch before it is listening. meilisearch is a sleepWith worker below
  # (wantedBy = karakeep-web), so this only adds ordering — no dependency cycle.
  systemd.services.karakeep-web.after     = [ "meilisearch.service" ];
  systemd.services.karakeep-workers.after = [ "meilisearch.service" ];

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ─────────────
  # The proxy on :8210 lazily starts karakeep-web on first connection and stops
  # the stack after idleSec. socketActivate clears the boot-time
  # wantedBy=multi-user.target on the realUnit and on each sleepWith worker,
  # rebinding them to karakeep-web's lifecycle (wantedBy + partOf). karakeep-init
  # is intentionally left on its default lifecycle: it's a RemainAfterExit oneshot
  # (~0 RAM) that must run at boot to generate /var/lib/karakeep/settings.env (a
  # persistent StateDirectory file) before the first wake.
  #
  # Behavior change to flag (like papra): while asleep, a bookmark saved via
  # the extension/app first wakes the stack; the worker then crawls + AI-tags it
  # asynchronously.
  services.socketActivate.karakeep = {
    enable   = true;
    realUnit = "karakeep-web.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString webPort}";
    idleSec  = 600;
    readyProbe = {
      # Next.js cold start binds ~seconds after systemd marks the unit active.
      # /api/health is karakeep's health endpoint; confirmed against the live
      # backend during bring-up.
      url          = "http://127.0.0.1:${toString webPort}/api/health";
      expectStatus = 200;
      timeoutSec   = 60;
    };
    workers = {
      "karakeep-workers.service".policy = "sleepWith";
      "meilisearch.service".policy      = "sleepWith";
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  # Karakeep keeps everything under /var/lib/karakeep on the SSD, outside
  # restic's /mnt/data scope — so it went unbacked from the day it landed, and
  # its units were never in the heavy list either, meaning nixos-rebuild-safe
  # left the Next.js stack plus Meilisearch resident during builds on a 3.9 GiB
  # box. Both are fixed by declaring them here.
  #
  # Meilisearch is a karakeep worker (sleepWith above), not a service of its
  # own, so it belongs to this registration. Its index is rebuildable from the
  # bookmarks in db.db and is deliberately not backed up.
  nic.services.karakeep = {
    backup        = [ "unit" ];
    backupUnits   = [ "karakeep-backup.service" ];   # backups.nix
    heavyUnits    = [
      "karakeep-web.service"
      "karakeep-workers.service"
      "meilisearch.service"
    ];
    heavyPriority = 125;

    public = {
      order   = 130;   # heads row 4, the catalogues (Gramps, ShowMyCards, Ryot)
      port    = 3500;
      backend = "http://127.0.0.1:8210";
      tile = {
        name        = "Karakeep";
        icon        = "karakeep.svg";
        category    = "Apps";
        description = "Bookmarks + read-later (AI-tagged)";
        # Stats via homepage-stats.py reading karakeep's SQLite read-only (no API
        # key, never wakes karakeep → preserves idle-sleep). NOT the native
        # `karakeep` widget, which would poll the API and keep it awake.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/karakeep";
          refreshInterval = 3600000;
          mappings = [
            # `Favorites` was 0 of 15 bookmarks — the feature is simply not used, so
            # the field could only render 0. Untagged rather than "added this week",
            # which would also be 0: with 32 tags over 15 bookmarks this collection
            # is over-tagged, so what the tagger has NOT reached is the actionable
            # count.
            { field = "bookmarks"; label = "Bookmarks"; format = "number"; }
            { field = "untagged";  label = "Untagged";  format = "number"; }
            { field = "tags";      label = "Tags";      format = "number"; }
          ];
        };
      };
    };
  };
}
