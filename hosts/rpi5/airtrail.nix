# hosts/rpi5/airtrail.nix
#
# AirTrail — self-hosted personal flight tracker (johanohly/AirTrail), packaged
# natively via the airtrail-nix flake (github:nSimonFR/airtrail-nix), same model
# as sure-nix. SvelteKit (adapter-node) + PostgreSQL; no containers.
#
# Runtime shape (see airtrail-nix/module.nix):
#   * airtrail-setup.service — oneshot, applies SQL migrations (idempotent),
#     seeds ~85k airports + airline icons on first boot (needs network).
#   * airtrail.service       — the Node HTTP server (adapter-node).
#
# Memory-constrained RPi5: steady-state RSS is ~65 MB, but per the socket-
# activation policy used across immich/sure/papra/karakeep the server also
# sleeps after 10 min idle (hosts/rpi5/lib/socket-activate.nix) and wakes on first
# request, returning to ~0 RAM at rest.
#
# The DB_URL (with password) is supplied via the agenix env file so the secret
# never lands in the world-readable Nix store; `databaseUrl` is left null.
{ config, lib, tailnetFqdn, ... }:
let
  internalPort = 13341;  # airtrail Node server (real backend bind, localhost only)
  proxyPort    = 8310;   # socket-activate proxy listen; Tailscale Serve → here
  # External tailnet HTTPS port: declared once in nic.services.airtrail.public
  # below, which also derives publicUrl for `origin`.
in
{
  # ── PostgreSQL: airtrail database + airtrail role ─────────────────────────
  # `unaccent` is pre-created here because an airtrail migration issues CREATE
  # EXTENSION, which needs superuser rights the airtrail role does not have.
  nic.pgRole.airtrail = {
    db           = "airtrail";
    user         = "airtrail";
    passwordFile = "/run/agenix/airtrail-pg-password";
    extensions   = [ "unaccent" ];
    privateUsers = false;
    description  = "Set airtrail PostgreSQL password + unaccent extension";
  };

  # ── AirTrail application (native Nix, via airtrail-nix flake) ─────────────
  services.airtrail = {
    enable          = true;
    host            = "127.0.0.1";
    port            = internalPort;
    origin          = config.nic.services.airtrail.public.publicUrl;
    environmentFile = "/run/agenix/airtrail-env";  # provides DB_URL (with password)
    # databaseUrl intentionally null — comes from environmentFile above.
  };

  # Migrations must run after the role/password/unaccent are in place.
  systemd.services.airtrail-setup = {
    after    = [ "airtrail-pg-setup.service" ];
    requires = [ "airtrail-pg-setup.service" ];
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────────
  # Proxy on :8310 lazily starts airtrail.service on first connection and stops
  # it after idleSec. socketActivate clears the boot-time wantedBy on the
  # realUnit. airtrail-setup (migrations) is intentionally left on its default
  # boot lifecycle — it's a RemainAfterExit oneshot (~0 RAM) that must have run
  # before the first wake (like karakeep-init).
  services.socketActivate.airtrail = {
    enable   = true;
    realUnit = "airtrail.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString internalPort}";
    idleSec  = 600;
    readyProbe = {
      # /api/ping is AirTrail's health endpoint (verified during bring-up).
      url          = "http://127.0.0.1:${toString internalPort}/api/ping";
      expectStatus = 200;
      # On the very FIRST cold start against an empty DB, AirTrail seeds ~85k
      # airports + fetches airline icons BEFORE adapter-node binds the port
      # (observed during bring-up: connection refused, then ~minutes later
      # "Listening"). Generous timeout so the first wake doesn't fail its probe;
      # the DB persists, so every subsequent wake binds in ~1s.
      timeoutSec   = 300;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.airtrail = {
    backup            = [ "postgres" ];
    postgresDatabases = [ "airtrail" ];
    heavyUnits        = [ "airtrail.service" ];
    heavyPriority     = 110;

    public = {
      order   = 160;
      port    = 3600;
      backend = "http://127.0.0.1:${toString proxyPort}";
      tile = {
        name        = "AirTrail";
        # AirTrail isn't in dashboard-icons, so point at its favicon.svg via
        # jsdelivr (pinned tag).
        icon        = "https://cdn.jsdelivr.net/gh/johanohly/AirTrail@v3.11.1/static/favicon.svg";
        category    = "Apps";
        description = "Personal flight tracker";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/airtrail";
          refreshInterval = 3600000;
          mappings = [
            { field = "flights"; label = "Flights"; format = "number"; }
            { field = "countries"; label = "Countries"; format = "number"; }
            { field = "hours"; label = "Hours"; format = "number"; }
          ];
        };
      };
    };
  };
}
