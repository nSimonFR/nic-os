# gramps-web.nix — host wiring for Gramps Web (genealogy).
#
# The package + base service live in the gramps-web-nix flake
# (github:nSimonFR/gramps-web-nix, imported in flake.nix) — same pattern as
# sure-nix / reactive-resume-nix. This file only does the nic-os-specific bits:
# enable the module, point it at shared Redis + the agenix secret, and wrap it
# with socket-activation. Frontend + gunicorn/celery come from the module.
#
# Not behind the 443 front-proxy path-mux (front-proxy.nix): Gramps Web's SPA
# hardcodes absolute API paths and its service worker needs root scope, so it
# can't be reliably served from a subpath (gramps-web#531). Like AFFiNE, it keeps
# its own origin — a dedicated Tailscale Serve port (5050, see services-registry.nix).
#
# Socket-activated lazy-start (rpi5/lib/socket-activate.nix): gunicorn binds
# 127.0.0.1:15051 and a proxy on 127.0.0.1:15050 (the Tailscale Serve backend for
# 5050) starts gramps-web.service — plus the Celery worker (sleepWith) — on the
# first connection. idleSec = null → no idle-stop, the units stay warm once woken.
# readyProbe gates the first request on /ready (unauthenticated 200) so a cold
# gunicorn (slow Gramps GI import) isn't dropped.
{ redisHost, redisPort, tailnetFqdn, ... }:
let
  backendPort = 15051; # gunicorn bind (module's host:port)
  proxyPort   = 15050; # socket-activate proxy listen; Tailscale Serve 5050 → here
in
{
  services.gramps-web = {
    enable        = true;
    host          = "127.0.0.1";
    port          = backendPort;
    # Multi-tree: serve several independent family trees (Dolou, Le Dreff, …) from
    # one instance. "*" flips GRAMPSWEB_TREE to TREE_MULTI so the frontend shows a
    # tree switcher; an ADMIN-role (5) user can view/manage all trees. Trees are
    # created offline via the bundled `gramps` CLI (see grampsdb dirs under dataDir).
    tree          = "*";
    baseUrl       = "https://${tailnetFqdn}:5050";
    # Redis DB 6 — 1=immich, 2=sure, 3=dawarich, 4=paperless, 5=nextcloud are taken.
    redisUrl      = "redis://${redisHost}:${toString redisPort}/6";
    secretKeyFile = "/run/agenix/gramps-web-secret";
    # Multi-tree hardening: prefix media paths by tree id so one tree's media can't
    # be reached from another (gramps-web warns loudly without this in TREE_MULTI).
    settings.GRAMPSWEB_MEDIA_PREFIX_TREE = "true";
  };

  # gramps-web-celery reaches Redis directly; make sure it's up first. (The web
  # unit's ordering is managed by the socket-activate proxy.)
  systemd.services.gramps-web.after = [ "redis-shared.service" ];
  systemd.services.gramps-web.wants = [ "redis-shared.service" ];
  systemd.services.gramps-web-celery.after = [ "redis-shared.service" ];
  systemd.services.gramps-web-celery.wants = [ "redis-shared.service" ];

  # Disable Gramps Web's opt-out telemetry. Its before_request hook POSTs to a
  # Google Cloud Run endpoint inline in the gunicorn worker and lets the failure
  # escape preprocess_request — with outbound blocked here every *authenticated*
  # request 502s (login 200s, then the SPA's first authed call dies). Flask reads
  # GRAMPSWEB_-prefixed env into config, so this sets config DISABLE_TELEMETRY.
  systemd.services.gramps-web.environment.GRAMPSWEB_DISABLE_TELEMETRY = "true";
  systemd.services.gramps-web-celery.environment.GRAMPSWEB_DISABLE_TELEMETRY = "true";

  services.socketActivate.gramps-web = {
    enable   = true;
    realUnit = "gramps-web.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString backendPort}";
    idleSec  = null;  # ignore idle — lazy-start only, stays up once warm
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/ready";
      expectStatus = 200;
      timeoutSec   = 120;
    };
    workers."gramps-web-celery.service".policy = "sleepWith";
  };
}
