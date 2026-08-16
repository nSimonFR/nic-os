# hosts/rpi5/ryot.nix
#
# Ryot — self-hosted media & life tracker (IgnisDa/ryot), packaged natively via
# the ryot-nix flake (github:nSimonFR/ryot-nix), same model as sure-nix /
# airtrail-nix. Container-only upstream, built from source (not in nixpkgs).
#
# Runtime shape (see ryot-nix/module.nix) — v10 is THREE processes:
#   * ryot-backend.service  — Rust axum + async-graphql GraphQL server (:13352).
#                             Self-applies embedded migrations on boot.
#   * ryot-frontend.service — React-Router 7 SSR server (:13351), reaches the
#                             backend THROUGH the proxy (API_URL → proxy/backend).
#   * ryot-proxy.service     — Caddy (:13350), THE entrypoint. Path-muxes the two
#                             and exposes /_i/* (Plex/Jellyfin auto-track webhook)
#                             → backend /webhooks/integrations. Tailscale Serve
#                             (external :3700) points here.
#
# Socket-activated (hosts/rpi5/lib/socket-activate.nix) as of this commit; it used
# to be deliberately always-on. The two reasons that justified that are handled,
# not gone:
#
#   * Plex/Jellyfin push webhooks (…/ryot/_i/<id>) land on the socket, which wakes
#     the stack and forwards — the request is queued, not refused. What a webhook
#     now costs is LATENCY: a cold wake is backend boot + SSR boot, and Plex does
#     not retry a webhook it considers timed out. idleSec is therefore 1800, not
#     the usual 600, so a normal evening's viewing keeps it warm after the first
#     event. If watch history starts going missing, this is the first suspect.
#   * "3-process cold start is fragile" is exactly what readyProbe exists for: no
#     traffic is forwarded until Caddy → frontend SSR → backend answers 200 end to
#     end, so a slow boot delays a request instead of 502-ing it.
#
# NOTE the entry is keyed `ryot-mux`, not `ryot`. The module derives its unit names
# as <name>-proxy, and ryot-nix already ships a unit called ryot-proxy (the Caddy
# above) — keying it `ryot` would silently merge the socket-proxy service INTO
# Caddy's unit and produce a hybrid with two ExecStarts that Requires/After itself.
#
# The DATABASE_URL (with password), SERVER_ADMIN_ACCESS_TOKEN and SESSION_SECRET
# come from the agenix env file so secrets never enter the world-readable Nix
# store.
#
# MOVIES_AND_SHOWS_TMDB_ACCESS_TOKEN also lives in that env file. Upstream Ryot
# binaries fetch shared metadata-provider keys at runtime, gated by a compile-time
# UNKEY_ROOT_KEY that ryot-nix builds set to "" — so our from-source build ships
# with NO TMDB key and every movie/show metadata lookup 401s ("Failed to retrieve
# metadata details"), breaking imports AND live Plex tracking. Fix: supply a free
# TMDB v4 "API Read Access Token" (themoviedb.org/settings/api) via this env var
# (env prefix MOVIES_AND_SHOWS_TMDB_, field access_token — see ryot config crate).
{ config, pkgs, lib, tailnetFqdn, ... }:
let
  backendPort  = 13352; # Rust backend (localhost)
  frontendPort = 13351; # React-Router SSR (localhost)
  # externalPort is what everything OUTSIDE Ryot talks to — the 443 path-mux, and
  # scripts/ryot-plex-import.sh, which hardcodes 13350. It is now the
  # socket-activation listener, so a connection there wakes the stack. Caddy itself
  # moved off it to proxyPort; that split is the whole mechanism, so if you collapse
  # these back into one port you get EADDRINUSE between the socket and Caddy.
  externalPort = 13350;
  proxyPort    = 13353; # Caddy entrypoint, now BEHIND the socket proxy
  # No servePort: Ryot has no port of its own. It sits behind the 443 path-mux at
  # /ryot (nic.services.ryot.public below). A `servePort = 3700` lingered here
  # long after that move — a port that no longer existed, read by nothing.

  # Ryot's SPA is now built with a /ryot/ base (ryot-nix frontend.nix basename +
  # vite base), so it lives under /ryot/ *everywhere*. Re-root Caddy's path-mux
  # under /ryot: backend routes strip the prefix (handle_path) then apply the stock
  # rewrites; frontend routes KEEP the prefix (handle, no strip) since the SSR
  # server expects the basename. Reuses the {$PORT}/{$CADDY_*_TARGET} env the
  # ryot-nix module already sets on ryot-proxy. Mirrors ${cfg.package}/etc/ryot/Caddyfile.
  caddyfile = pkgs.writeText "ryot-subpath-Caddyfile" ''
    {
      admin off
      auto_https off
    }

    :{$PORT:8000} {
      vars {
        frontend_url {$CADDY_FRONTEND_TARGET:127.0.0.1:3000}
        backend_url {$CADDY_BACKEND_TARGET:127.0.0.1:5000}
      }

      handle_path /ryot/_i/* {
        rewrite * /webhooks/integrations{path}
        reverse_proxy {vars.backend_url}
      }
      handle_path /ryot/backend* {
        reverse_proxy {vars.backend_url}
      }
      # The SPA's browser-side GraphQL client posts to <base>/graphql — i.e.
      # /ryot/graphql — whereas the SSR loaders use /ryot/backend/graphql. Without
      # this route /ryot/graphql falls through to the frontend catch-all and 404s,
      # breaking every client-side query/mutation in the web UI. Send it to the
      # backend's /graphql (same target the /backend* strip reaches). Upstream gap
      # in the ryot-nix subpath patch — the client path should carry /backend.
      handle /ryot/graphql {
        rewrite * /graphql
        reverse_proxy {vars.backend_url}
      }
      handle_path /ryot/u/* {
        rewrite * /api/sharing{path}?isAccountDefault=true
        reverse_proxy {vars.frontend_url}
      }
      handle_path /ryot/_s/* {
        rewrite * /api/sharing{path}
        reverse_proxy {vars.frontend_url}
      }
      handle /ryot/* {
        reverse_proxy {vars.frontend_url}
      }
    }
  '';
in
{
  # ── PostgreSQL: ryot database + ryot role ─────────────────────────────────
  nic.pgRole.ryot = {
    db           = "ryot";
    user         = "ryot";
    passwordFile = "/run/agenix/ryot-pg-password";
    privateUsers = false;
  };

  # ── Ryot application (native Nix, via ryot-nix flake) ─────────────────────
  services.ryot = {
    enable          = true;
    inherit backendPort frontendPort proxyPort;
    # Public URL Ryot is served from, on the single 443 funnel front-proxy → sets
    # backend FRONTEND_URL (absolute/share links). Ryot lives under /ryot/ now.
    frontendUrl     = "https://${tailnetFqdn}/ryot";
    environmentFile = "/run/agenix/ryot-env"; # DATABASE_URL + SERVER_ADMIN_ACCESS_TOKEN + SESSION_SECRET + MOVIES_AND_SHOWS_TMDB_ACCESS_TOKEN
  };

  # The backend self-migrates on boot, so it must start after the role/password
  # exist. (No separate migrate oneshot — migrations are embedded.)
  systemd.services.ryot-backend = {
    after    = [ "ryot-pg-setup.service" ];
    requires = [ "ryot-pg-setup.service" ];
  };

  # Run the proxy with the /ryot-rooted Caddyfile instead of the stock root one
  # baked into the package.
  systemd.services.ryot-proxy.serviceConfig.ExecStart =
    lib.mkForce "${pkgs.caddy}/bin/caddy run --adapter caddyfile --config ${caddyfile}";

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ──────────
  # realUnit is Caddy, the entrypoint; the two heavy tiers ride along as workers
  # (sleepWith → wantedBy + partOf Caddy), so all three wake and sleep together.
  # Caddy is cheap and starts instantly, which is why the readyProbe has to go
  # THROUGH it rather than trusting systemd's "active": /ryot/auth is rendered by
  # the SSR frontend, whose loader queries the backend, so a 200 there is the only
  # single check that proves the whole chain is up. /ryot/ itself 302s to it, so
  # probing the root would pass while the frontend was still warming.
  services.socketActivate.ryot-mux = {
    enable   = true;
    realUnit = "ryot-proxy.service";
    listen   = [ "127.0.0.1:${toString externalPort}" ];
    backend  = "127.0.0.1:${toString proxyPort}";
    # 30 min, vs the 600s used elsewhere — see the webhook-latency note in the
    # header. Cold waking on every Plex event would risk dropped watch history.
    idleSec  = 1800;
    readyProbe = {
      url          = "http://127.0.0.1:${toString proxyPort}/ryot/auth";
      expectStatus = 200;
      # Rust backend boot (it self-applies migrations) + Node SSR boot on a Pi.
      timeoutSec   = 180;
    };
    workers = {
      "ryot-backend.service".policy  = "sleepWith";
      "ryot-frontend.service".policy = "sleepWith";
    };
  };

  # SSR loaders reach the backend through the re-rooted Caddy /ryot/backend route
  # (module default is the stock /backend, which no longer exists in our Caddyfile).
  systemd.services.ryot-frontend.environment.API_URL =
    lib.mkForce "http://127.0.0.1:${toString proxyPort}/ryot/backend";

  # ── Nightly Plex → Ryot watch-history sync (no Plex Pass) ─────────────────
  # Ryot v10 has no working Plex pull for watch progress (yank only mirrors
  # libraries; the sink webhook needs Plex Pass, which nSimon lacks). The only
  # no-Plex-Pass path is to re-run the one-time Plex importer on a schedule — but
  # it isn't idempotent (seen has no unique constraint), so scripts/ryot-plex-import.sh
  # imports both shared servers, waits for the jobs, then dedups seen.
  systemd.services.ryot-plex-import = {
    description = "Nightly Plex → Ryot watch-history re-import + dedup";
    after = [ "ryot-proxy.service" "ryot-backend.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "ryot";
      # DATABASE_URL from ryot-env; RYOT_LOGIN_* + PLEX_IMPORT_SERVERS from ryot-import-env.
      EnvironmentFile = [ "/run/agenix/ryot-env" "/run/agenix/ryot-import-env" ];
      ExecStart = lib.getExe (pkgs.writeShellApplication {
        name = "ryot-plex-import";
        runtimeInputs = [ pkgs.curl pkgs.jq pkgs.postgresql pkgs.coreutils ];
        text = builtins.readFile ./scripts/ryot-plex-import.sh;
      });
    };
  };
  systemd.timers.ryot-plex-import = {
    description = "Nightly Plex → Ryot re-import";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:40:00";  # after the 03:00-04:00 backup window
      Persistent = true;              # catch up a missed run if the Pi was off
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.ryot = {
    backup            = [ "postgres" ];
    postgresDatabases = [ "ryot" ];
    heavyUnits        = [ "ryot-backend.service" "ryot-frontend.service" ];
    heavyPriority     = 90;

    # Prefix KEPT (no strip): the SSR frontend is built with a /ryot/ base and
    # basename, and Caddy is re-rooted to mux under /ryot, so front-proxy.nix
    # forwards /ryot/* verbatim. This also makes the Plex webhook (…/ryot/_i/<id>)
    # publicly reachable.
    public = {
      order   = 160;
      port    = 443;
      # externalPort, NOT proxyPort: the path-mux must land on the socket so a
      # request wakes the stack. Pointing this at Caddy directly would work only
      # while Ryot happened to be awake, and 502 the rest of the time.
      backend = "http://127.0.0.1:${toString externalPort}";
      proxied = true;
      muxPath = "/ryot";
      tile = {
        name        = "Ryot";
        icon        = "ryot.svg";
        category    = "Apps";
        description = "Media & life tracker";
        # Reads Ryot's Postgres directly (daily-cached, superuser) — no API token
        # on the tile. "Hours" excludes video-game playtime; see
        # RYOT_MEDIA_HOURS_SQL for why.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/ryot";
          refreshInterval = 3600000;
          mappings = [
            { field = "seen";     label = "Media seen"; format = "number"; }
            { field = "hours";    label = "Hours seen"; format = "number"; suffix = "h"; }
            { field = "workouts"; label = "Workouts";   format = "number"; }
          ];
        };
      };
    };
  };
}
