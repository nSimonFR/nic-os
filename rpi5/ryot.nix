# rpi5/ryot.nix
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
# Always-on (NOT socket-activated like airtrail/gramps): the Plex/Jellyfin push
# integrations must be awake to receive webhooks, and a 3-process app makes
# cold-start wake fragile. Steady-state RAM is modest (backend idles low).
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
{ config, pkgs, lib, pgHost, tailnetFqdn, ... }:
let
  backendPort  = 13352; # Rust backend (localhost)
  frontendPort = 13351; # React-Router SSR (localhost)
  proxyPort    = 13350; # Caddy entrypoint; Tailscale Serve → here
  servePort    = 3700;  # external tailnet HTTPS port (see services-registry.nix)

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
  services.postgresql = {
    ensureDatabases = [ "ryot" ];
    ensureUsers = [{ name = "ryot"; }];

    # ryot connects via TCP with scram-sha-256 (DATABASE_URL host = 127.0.0.1).
    authentication = lib.mkAfter ''
      host  ryot  ryot  ${pgHost}/32  scram-sha-256
    '';
  };

  # Set the ryot role password (from agenix) + grant DB ownership.
  # ensurePasswordFile is absent in 25.11 → oneshot instead (pattern shared with
  # airtrail-pg-setup). Must order after postgresql-setup (which runs ensureUsers).
  systemd.services.ryot-pg-setup = {
    description = "Set ryot PostgreSQL password + DB ownership";
    after    = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      # RPi5 kernel has no user namespaces; default PrivateUsers=true breaks it.
      PrivateUsers = lib.mkForce false;
    };
    script = ''
      password=$(cat /run/agenix/ryot-pg-password)
      # psql :'pw' interpolation only works via stdin/-f, not -c.
      ${pkgs.postgresql}/bin/psql -v pw="$password" <<< "ALTER USER ryot WITH PASSWORD :'pw';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE ryot OWNER TO ryot;"
    '';
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
}
