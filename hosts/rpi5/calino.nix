# hosts/rpi5/calino.nix
#
# Calino — a web calendar for the calendars that already live in Nextcloud
# (pkgs/services/calino.nix). No second store: the events, tasks, journals and
# contacts are Nextcloud's, reached over CalDAV/CardDAV straight from the
# browser. Credentials sit in the browser's localStorage, the event cache in
# Dexie/IndexedDB.
#
# Calino itself has no process. This module is one nginx vhost on
# 127.0.0.1:<internalPort> that does three things:
#
#   /                            → static files from the nix store (SPA)
#   /nextcloud/remote.php/dav/   → 127.0.0.1:8091 (Nextcloud's DAV endpoint)
#   /feeds/                      → windowed .ics files written by ics-mirror
#
# …plus the one timer that fills /feeds/. See "WHY THE ICS MIRROR" below.
#
# ⚠ WHY CALINO IS NOT ON THE 443 PATH-MUX. It cannot live at a sub-path: App.tsx
#   mounts <BrowserRouter> with no `basename`, every route (/month, /week,
#   /contacts, …) is root-absolute, the view↔path map compares raw
#   location.pathname against literal keys, and vite.config.ts hardcodes
#   `base: '/'`. Vite's `base` re-roots assets, never the router. Same reason
#   front-proxy.nix's header says "AFFiNE is NOT here anymore — its SPA router
#   insists on root paths." Calino therefore owns an origin root: its own
#   `tailscale serve` port. That also makes front-proxy.nix's PWA-manifest trap
#   inapplicable — Calino's root-absolute start_url/scope/sw.js registration are
#   correct as built.
#
# ⚠ WHY THE DAV RE-PROXY. SabreDAV exposes no CORS knob, so a browser at this
#   origin cannot talk to Nextcloud at another one; upstream's answer is a
#   bundled CORS-proxy container (docs/DOCKER.md). Serving DAV from the SAME
#   origin as the SPA sidesteps CORS entirely, in one nginx location, with zero
#   new processes.
#
# ⚠ WHY THE ICS MIRROR (and why `/gcal/` is gone). Calino's own webcal
#   subscriptions fetch from the BROWSER and persist every parsed event into
#   `calino-storage` in raw localStorage — capped at ~5 MB per origin. The TRUSK
#   Google feed is 6234 VEVENTs / 9.8 MB, so subscribing to it directly overflowed the
#   quota and Calino toasted "Storage is full. Your data may not be saved.", after
#   which the store silently stopped persisting.
#
#   `ics-mirror` (nicos-scripts) fetches each feed SERVER-side on a timer, keeps
#   only what can render in a -3/+12-month window (6234 → ~216 events, 9.8 MB →
#   ~370 kB) and writes a small .ics that this vhost serves from Calino's own
#   origin. Calino subscribes same-origin.
#
#   That removes the `^~ /gcal/` passthrough entirely: it existed only because
#   calendar.google.com sends no Access-Control-Allow-Origin and a BROWSER
#   therefore could not fetch the feed. A server-side fetch has no CORS to satisfy
#   (verified: a direct GET of the feed answers 200), so the proxy had no consumer
#   left — and with it goes its open-relay-shaped "Proxy URL" footgun.
#
#   ⚠ The mirror is why the TRUSK feed must NOT go anywhere near Nextcloud: this
#     origin is tailnet-only (`public.port` below is served, never funnelled),
#     whereas Nextcloud is the bare-URL target of the PUBLIC 443 funnel
#     (front-proxy.nix). Work-calendar data stays on the tailnet by construction.
{ config, pkgs, ... }:
let
  internalPort = 13347;

  # Written by ics-mirror.service, read by the `/feeds/` location below. Not a
  # nix-store path: the contents change on a timer, not on a rebuild.
  mirrorDir = "/var/lib/ics-mirror";
  mirrorOutDir = "${mirrorDir}/public";

  # Same fixpoint as showmycards.nix:49 — read back the publicUrl derived from
  # the port declared in nic.services.calino.public below, instead of spelling
  # the origin twice.
  siteUrl = config.nic.services.calino.public.publicUrl;

  # Single-consumer package, so it stays a callPackage at its one use site
  # rather than an overlay entry (see pkgs/overlay.nix's header).
  calino = pkgs.callPackage ../../pkgs/services/calino.nix { inherit siteUrl; };

  # Nextcloud's internal nginx vhost (nextcloud.nix:18).
  nextcloudBackend = "http://127.0.0.1:8091";
in
{
  services.nginx.virtualHosts."calino" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = internalPort;
        ssl = false;
      }
    ];
    root = "${calino}/share/calino/dist";

    # This nginx has recommendedGzipSettings / ProxySettings / Optimisation all
    # FALSE (verified), so gzip is opt-in per vhost and every proxy header is
    # hand-written below.
    extraConfig = ''
      absolute_redirect off;

      gzip on;
      gzip_vary on;
      gzip_min_length 1024;
      gzip_proxied any;
      gzip_comp_level 5;
      gzip_types text/plain text/css text/javascript application/javascript
                 application/json application/manifest+json image/svg+xml;
    '';

    locations = {
      # SPA fallback: every route in App.tsx is client-side, so a deep link must
      # return index.html rather than 404.
      "/" = {
        tryFiles = "$uri $uri/ /index.html";
      };

      # Vite content-hashes everything under /assets/, so these are safe to pin
      # forever.
      "/assets/" = {
        extraConfig = ''
          add_header Cache-Control "public, max-age=31536000, immutable" always;
        '';
      };

      # These two must NEVER be cached, or a version bump can never land: the
      # HTML is what names the new hashed assets, and the SW is what replaces
      # the old ones. (`add_header` does not merge across levels, so each
      # location restates what it needs.)
      "= /index.html" = {
        extraConfig = ''
          add_header Cache-Control "no-store" always;
        '';
      };
      "= /sw.js" = {
        # docs/DOCKER.md: "Ensure your reverse proxy returns
        # Service-Worker-Allowed: / header for /sw.js". Without it the worker is
        # scope-limited to its own directory and offline mode silently does
        # nothing.
        extraConfig = ''
          add_header Service-Worker-Allowed "/" always;
          add_header Cache-Control "no-store" always;
        '';
      };

      # DAV auto-discovery lands at an origin's root; point it at the mount
      # below. Mirrors front-proxy.nix:178-179.
      "= /.well-known/caldav" = {
        return = "301 /nextcloud/remote.php/dav/";
      };
      "= /.well-known/carddav" = {
        return = "301 /nextcloud/remote.php/dav/";
      };

      # Blast-radius guard. A Nextcloud app password is full-account, so the
      # credential Calino holds in localStorage would otherwise reach every
      # file in Files too. Refuse the files endpoint — a longer prefix than the
      # DAV mount below, so nginx picks it first.
      "^~ /nextcloud/remote.php/dav/files/" = {
        return = "403";
      };

      # ── Same-origin DAV ────────────────────────────────────────────────────
      # The mount path MUST be /nextcloud/remote.php/dav/. Nextcloud builds DAV
      # hrefs as OC::$WEBROOT . '/remote.php/dav/', and overwritewebroot
      # (=/nextcloud) applies because overwritecondaddr="^127\.0\.0\.1$" matches
      # unconditionally here — nginx reaches php-fpm over a unix socket, so
      # REMOTE_ADDR is always 127.0.0.1. Every href in a multistatus therefore
      # carries /nextcloud, and a shorter alias would break multiget and
      # sync-collection on the second hop.
      "^~ /nextcloud/remote.php/dav/" = {
        proxyPass = "${nextcloudBackend}/remote.php/dav/";
        extraConfig = ''
          # $host is the Host header WITHOUT the port, so this yields the bare
          # tailnet FQDN and satisfies Nextcloud's trusted_domains even though
          # the browser dialled :3800. Same shape as front-proxy.nix:50.
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto https;

          # ⚠ LOAD-BEARING, NOT POLISH. Cookies are host-scoped and
          # PORT-AGNOSTIC, so :3800 and :443 share one jar, and Nextcloud scopes
          # its cookies to path=/nextcloud — an exact prefix of this mount.
          # Without these two lines the calendar is broken for exactly the
          # person who is also logged into Nextcloud:
          #   * apps/dav Auth.php::requiresCSRFCheck — PROPFIND/REPORT/PUT/
          #     DELETE are not in $methodsWithoutCsrf, so a live session cookie
          #     makes isLoggedIn() true with DAV_AUTHENTICATED null → 401 "CSRF
          #     check not passed." BEFORE Basic auth is ever read. (Symptom:
          #     works in a private window, 401s in the normal one.)
          #   * Auth.php::auth's "//Fix for broken webdav clients" branch — GET
          #     skips the CSRF gate and returns the SESSION user's principal,
          #     silently ignoring the Authorization header.
          #   * Each DAV response's Set-Cookie would clobber the :443 session,
          #     logging you out of Nextcloud from the calendar tab.
          proxy_set_header  Cookie "";
          proxy_hide_header Set-Cookie;

          client_max_body_size 32m;      # ICS imports
          proxy_request_buffering off;
          proxy_buffering off;
          proxy_read_timeout 300s;
          proxy_send_timeout 300s;
        '';
      };

      # Tombstone for the retired passthrough. Without it `/gcal/…` falls through
      # to the SPA fallback and answers 200 with index.html — so a browser still
      # holding the old subscription would hand HTML to an ICS parser and see an
      # empty calendar rather than an error. 410 says what actually happened.
      # Delete this once no browser has a /gcal/ subscription left.
      "^~ /gcal/" = {
        return = "410";
      };

      # ── Same-origin windowed ICS feeds ─────────────────────────────────────
      # Replaces the old `^~ /gcal/` passthrough to calendar.google.com. These
      # files are written by ics-mirror.service below; Calino subscribes to
      # <origin>/feeds/<slug>.ics (Sidebar → "Subscribe to Calendar").
      #
      # Why a same-origin FILE rather than a proxy: the browser never touches
      # Google, so there is no CORS wall to work around and no secret feed token
      # in the browser — the token lives only in the agenix secret the timer
      # reads. It also means the browser downloads ~370 kB instead of 9.8 MB,
      # which is the whole point (see WHY THE ICS MIRROR in the header).
      #
      # ⚠ Leave upstream's "Proxy URL" field empty. `buildProxyUrl` makes
      #   `<proxy>/<urlencoded-origin><path>` — an arbitrary origin as a path
      #   segment, i.e. an open relay — and it is unmatchable in nginx anyway,
      #   which decodes %3A/%2F and merges slashes BEFORE location matching.
      "^~ /feeds/" = {
        # Trailing slash on both sides: `alias` replaces the matched prefix, so
        # /feeds/trusk.ics resolves to <mirrorOutDir>/trusk.ics.
        alias = "${mirrorOutDir}/";
        extraConfig = ''
          limit_except GET HEAD {
            deny all;
          }

          # The mirror rewrites these on a timer and Calino re-fetches on its own
          # refresh interval, so a cached copy would just pin a stale calendar.
          add_header Cache-Control "no-store" always;

          # No directory listing: the slugs are not secret, but there is no
          # reason to enumerate them either.
          autoindex off;

          # ~370 kB of highly repetitive text — the one place on this vhost where
          # gzip earns its keep. (`gzip_types` in extraConfig above does not list
          # text/calendar, so name it here.)
          gzip_types text/calendar;
        '';
      };
    };
  };

  # ── ICS mirror ──────────────────────────────────────────────────────────────
  # Fetches each feed in the agenix secret, windows it, writes <slug>.ics into
  # mirrorOutDir for the `/feeds/` location above. See WHY THE ICS MIRROR in the
  # header for what this replaces and why it is not a CalDAV write.
  systemd.services.ics-mirror = {
    description = "Mirror remote ICS feeds, windowed, for Calino to subscribe to";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      ICS_MIRROR_FEEDS_FILE = config.age.secrets.calino-ics-feeds.path;
      ICS_MIRROR_OUT_DIR = mirrorOutDir;
      ICS_MIRROR_STATE_DIR = mirrorDir;
      # -3/+12 months. Measured on the TRUSK feed: 6234 events → 216, 9.8 MB →
      # 370 kB. Widening this is the knob to turn if you need more back-scroll;
      # the ~5 MB localStorage cap is the ceiling it is trading against.
      ICS_MIRROR_BACK_DAYS = "92";
      ICS_MIRROR_FWD_DAYS = "365";
    };
    serviceConfig = {
      Type = "oneshot";
      # root only to read the 0400 feeds secret; it writes nowhere else. The
      # StateDirectory is 0755 so the nginx worker can read what it writes.
      User = "root";
      StateDirectory = "ics-mirror";
      StateDirectoryMode = "0755";
      ExecStart = "${pkgs.nicos-scripts}/bin/ics-mirror";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      # AF_UNIX is load-bearing, not boilerplate: glibc's NSS talks to
      # systemd-resolved over /run/systemd/resolve/io.systemd.Resolve, so without
      # it every fetch dies on name resolution rather than on the network.
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };
  systemd.timers.ics-mirror = {
    description = "Refresh the windowed ICS mirrors";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      # ⚠ This is NOT what bounds freshness. Google serves the private
      # `basic.ics` from its own publishing cache and has historically lagged
      # real edits by hours, so polling faster buys nothing. 15 min keeps the
      # worst-case OUR side adds small; `last_changed_at` in
      # /var/lib/ics-mirror/state.json records when the body actually moved, so
      # the real cadence can be measured and this re-tuned on evidence.
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────
  nic.services.calino = {
    backup = [ "none" ];
    backupNote = ''
      stateless — static files out of the nix store. The only state (the CalDAV
      URL + app password, plus a Dexie event cache) lives in the browser. The
      calendars themselves are Nextcloud's, already covered by its Postgres dump
      and /mnt/data. /var/lib/ics-mirror is a regenerable cache: every file in it
      is rebuilt from the upstream feeds on the next timer tick.
    '';
    # Calino serves from the nix store, but the mirror timer parses a ~10 MB ICS
    # (~127 MB peak RSS, measured). Cheap to shed while a build needs the RAM —
    # heavy-shed only restores units that were active, so the dormant oneshot is
    # never spuriously started. nginx stays up: it is infra.
    heavyUnits = [ "ics-mirror.timer" "ics-mirror.service" ];

    public = {
      # Directly after Nextcloud (30), which is the store these numbers come from;
      # AFFiNE moved up to 25 to make that pair adjacent.
      order = 90;
      port = 3800;
      backend = "http://127.0.0.1:${toString internalPort}";
      tile = {
        name = "Calino";
        icon = "mdi-calendar-month";
        category = "Apps";
        description = "Calendar (Nextcloud CalDAV)";
        # Calino has no store, no database and no process, so unlike every other
        # tile there is nothing of its own to read — these come from the calendars
        # it renders, i.e. Nextcloud's CalDAV. See fetch_calino for why all three
        # are counts obtained with a server-side filter rather than computed from
        # oc_calendarobjects (recurrence).
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/calino";
          refreshInterval = 3600000;
          mappings = [
            { field = "today"; label = "Today"; format = "number"; }
            { field = "week"; label = "7 days"; format = "number"; }
            { field = "tasks"; label = "Tasks due"; format = "number"; }
          ];
        };
      };
    };
  };
}
