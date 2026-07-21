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
    frontendUrl     = "https://ryot.${tailnetFqdn}";
    environmentFile = "/run/agenix/ryot-env"; # DATABASE_URL + SERVER_ADMIN_ACCESS_TOKEN + SESSION_SECRET + MOVIES_AND_SHOWS_TMDB_ACCESS_TOKEN
  };

  # The backend self-migrates on boot, so it must start after the role/password
  # exist. (No separate migrate oneshot — migrations are embedded.)
  systemd.services.ryot-backend = {
    after    = [ "ryot-pg-setup.service" ];
    requires = [ "ryot-pg-setup.service" ];
  };
}
