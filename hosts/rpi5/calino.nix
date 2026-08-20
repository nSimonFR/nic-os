# hosts/rpi5/calino.nix
#
# Calino — a web calendar for the calendars that already live in Nextcloud
# (pkgs/services/calino.nix). No second store: the events, tasks, journals and
# contacts are Nextcloud's, reached over CalDAV/CardDAV straight from the
# browser. Credentials sit in the browser's localStorage, the event cache in
# Dexie/IndexedDB.
#
# So there is NO systemd unit here. This module is one nginx vhost on
# 127.0.0.1:<internalPort> that does two things:
#
#   /                            → static files from the nix store (SPA)
#   /nextcloud/remote.php/dav/   → 127.0.0.1:8091 (Nextcloud's DAV endpoint)
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
{ config, pkgs, ... }:
let
  internalPort = 13347;

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
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────
  nic.services.calino = {
    backup = [ "none" ];
    backupNote = ''
      stateless — static files out of the nix store. The only state (the CalDAV
      URL + app password, plus a Dexie event cache) lives in the browser. The
      calendars themselves are Nextcloud's, already covered by its Postgres dump
      and /mnt/data.
    '';
    # No process of its own; nginx is infra that nixos-rebuild-safe leaves up.
    heavyUnits = [ ];

    public = {
      # Directly after Nextcloud (30), which is the store these numbers come from;
      # AFFiNE moved up to 25 to make that pair adjacent.
      order = 35;
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
