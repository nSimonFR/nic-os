# front-proxy.nix — nginx path-mux on the single public 443 Tailscale Funnel.
#
# Tailscale Funnel only permits ports 443/8443/10000, and 8443→AFFiNE / 10000→Immich
# are taken. To expose Nextcloud and Cyrus publicly without a fourth port, one Funnel
# on 443 points at this vhost, which routes by path:
#
#   tailscale funnel --https=443  →  127.0.0.1:8092 (this vhost)
#     /                 → 301 → /nextcloud/
#     /nextcloud/       → 127.0.0.1:8091/  (Nextcloud — prefix STRIPPED: NC routes at its
#                                            vhost root; overwritewebroot=/nextcloud only
#                                            rewrites the links NC generates)
#     /cyrus/           → 127.0.0.1:3456/  (Cyrus — prefix STRIPPED: cyrus mounts its
#                                            routes (/callback, /linear-webhook,
#                                            /github-webhook) at root and only knows its
#                                            public base via CYRUS_BASE_URL=…/cyrus, so
#                                            stripping /cyrus lands each at the right route)
#     /.well-known/{caldav,carddav} → 301 → /nextcloud/remote.php/dav/  (DAV auto-discovery
#                                            lands at the domain root; redirect to Nextcloud)
#
# AFFiNE is NOT here anymore — its SPA router insists on root paths, so it runs at the
# root of its own 8443 Funnel (see affine.nix / services-registry.nix). Reuses the nginx
# instance the Nextcloud module already runs (no extra process). The funnel entry that
# targets :8092 lives in services-registry.nix (Infrastructure category); Nextcloud +
# Cyrus entries carry `proxied = true` so tailscale-serve.nix emits no direct
# serve/funnel command for them — this vhost fronts them instead.
{ ... }:
let
  # Headers every proxied location forwards. X-Forwarded-Proto=https is required so
  # Nextcloud (overwritecondaddr=^127\.0\.0\.1$, overwriteprotocol=https) generates
  # https links behind the TLS-terminating Tailscale Funnel.
  fwdHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  '';
in
{
  services.nginx.virtualHosts."front-proxy" = {
    # Only vhost on this port; Tailscale terminates TLS and forwards plain HTTP here.
    listen = [ { addr = "127.0.0.1"; port = 8092; ssl = false; } ];

    # Emit relative Location headers on our `return 301`s. Otherwise nginx builds
    # absolute redirects from its own listen socket (http://<host>:8092/…), leaking
    # the internal port and downgrading to http. Relative headers let the browser
    # resolve against the original https://<host>/ request.
    extraConfig = ''
      absolute_redirect off;
    '';

    locations = {
      # Bare URL → Nextcloud (the main human-facing app on this funnel).
      "= /" = { return = "301 /nextcloud/"; };

      # Nextcloud: trailing slashes on both location and proxyPass strip /nextcloud
      # before forwarding to NC's root vhost.
      "= /nextcloud" = { return = "301 /nextcloud/"; };
      "/nextcloud/" = {
        proxyPass = "http://127.0.0.1:8091/";
        proxyWebsockets = true;
        extraConfig = ''
          ${fwdHeaders}
          client_max_body_size 10G;      # large file uploads
          proxy_request_buffering off;   # stream uploads rather than buffer to disk
          proxy_read_timeout 3600s;
          proxy_send_timeout 3600s;
        '';
      };

      # Cyrus: trailing slash on both strips /cyrus before forwarding. Cyrus's
      # Fastify server mounts /callback, /linear-webhook, /github-webhook at its
      # root, so /cyrus/linear-webhook → 3456/linear-webhook. proxyWebsockets in
      # case any endpoint upgrades (harmless otherwise).
      "= /cyrus" = { return = "301 /cyrus/"; };
      "/cyrus/" = {
        proxyPass = "http://127.0.0.1:3456/";
        proxyWebsockets = true;
        extraConfig = fwdHeaders;
      };

      # Sure (Rails, socket-activated). UNLIKE Nextcloud/Cyrus this is passed
      # through UNCHANGED (no trailing-slash strip): sure-nix's config.ru mounts
      # the app under RAILS_RELATIVE_URL_ROOT=/sure via Rack::URLMap, which does
      # the internal SCRIPT_NAME strip itself. Proxy to the socket-activate port
      # (13334) so a request wakes Puma; readyProbe hits /sure/up.
      "/sure" = {
        proxyPass = "http://127.0.0.1:13334";
        proxyWebsockets = true;
        extraConfig = fwdHeaders;
      };

      # Reactive Resume (rxresu.me v5, socket-activated). Prefix STRIPPED (trailing
      # slash on both) — the server is root-native; the SPA is built with Vite
      # base=/rxresume/ so the browser requests everything under /rxresume/ (assets,
      # /api, /auth), and the server's browser-facing URLs (PDF/storage/share) carry
      # /rxresume via APP_URL. Proxy to the socket-activate port (13336) so a request
      # wakes the Node backend; readyProbe hits /api/health.
      "= /rxresume" = { return = "301 /rxresume/"; };
      "/rxresume/" = {
        proxyPass = "http://127.0.0.1:13336/";
        proxyWebsockets = true;
        extraConfig = ''
          ${fwdHeaders}
          # Cold-wake (socket-activation) takes ~18s; give the first request
          # headroom over nginx's 60s default so it doesn't 504 (readyProbe=120s).
          proxy_read_timeout 120s;
        '';
      };

      # CalDAV/CardDAV auto-discovery at the domain root → Nextcloud's DAV endpoint.
      "= /.well-known/caldav"  = { return = "301 /nextcloud/remote.php/dav/"; };
      "= /.well-known/carddav" = { return = "301 /nextcloud/remote.php/dav/"; };
    };
  };
}
