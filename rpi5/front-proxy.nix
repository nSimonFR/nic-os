# front-proxy.nix — nginx path-mux on the single public 443 Tailscale Funnel.
#
# Tailscale Funnel only permits ports 443/8443/10000, and 8443→Cyrus / 10000→Immich
# are taken. To expose Nextcloud publicly without evicting anyone, one Funnel on 443
# points at this vhost, which routes by path to AFFiNE and Nextcloud on the same host:
#
#   tailscale funnel --https=443  →  127.0.0.1:8092 (this vhost)
#     /                 → 301 → /affine/
#     /affine           → 127.0.0.1:13010  (AFFiNE — prefix PASSED THROUGH: AFFiNE runs
#                                            under a NestJS global prefix set by
#                                            AFFINE_SERVER_SUB_PATH=/affine, so it expects
#                                            the /affine prefix on incoming requests)
#     /nextcloud/       → 127.0.0.1:8091/  (Nextcloud — prefix STRIPPED: NC routes at its
#                                            vhost root; overwritewebroot=/nextcloud only
#                                            rewrites the links NC generates)
#     /.well-known/{caldav,carddav} → 301 → /nextcloud/remote.php/dav/  (DAV auto-discovery
#                                            lands at the domain root, which now serves
#                                            AFFiNE, so redirect it to Nextcloud)
#
# Reuses the nginx instance the Nextcloud module already runs (no extra process). The
# funnel entry that targets :8092 lives in services-registry.nix (Infrastructure category);
# AFFiNE + Nextcloud entries carry `proxied = true` so tailscale-serve.nix emits no direct
# serve/funnel command for them — this vhost fronts them instead.
{ ... }:
let
  # Headers every proxied location forwards. X-Forwarded-Proto=https is required so
  # Nextcloud (overwritecondaddr=^127\.0\.0\.1$, overwriteprotocol=https) and AFFiNE
  # generate https links behind the TLS-terminating Tailscale Funnel.
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
      # Bare URL used to be AFFiNE at root — send humans to /affine/.
      "= /" = { return = "301 /affine/"; };

      # AFFiNE human URL + API: forward the /affine prefix intact (NestJS global
      # prefix — do NOT strip). Handles /affine, /affine/graphql, /affine/*.
      "/affine" = {
        proxyPass = "http://127.0.0.1:13010";
        proxyWebsockets = true; # doc sync (graphql-ws / socket.io)
        extraConfig = fwdHeaders;
      };

      # Catch-all: AFFiNE's web UI emits root-relative asset URLs (/js, /styles*.css,
      # /manifest.json, lazy-loaded chunks) because the self-hosted build's frontend
      # publicPath can't be pinned to /affine. Map every other root path onto the
      # /affine backend (which serves the assets under the global prefix). More
      # specific locations (/affine, /nextcloud/, /.well-known/*) win over this, so
      # only AFFiNE's stray root assets land here. proxyPass has a URI with a
      # trailing slash (/affine/) so nginx rewrites the leading "/" → "/affine/"
      # (e.g. /js/x → /affine/js/x). Without the trailing slash it would emit
      # /affinejs/x and 404.
      "/" = {
        proxyPass = "http://127.0.0.1:13010/affine/";
        proxyWebsockets = true;
        extraConfig = fwdHeaders;
      };

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

      # CalDAV/CardDAV auto-discovery at the domain root → Nextcloud's DAV endpoint.
      "= /.well-known/caldav"  = { return = "301 /nextcloud/remote.php/dav/"; };
      "= /.well-known/carddav" = { return = "301 /nextcloud/remote.php/dav/"; };
    };
  };
}
