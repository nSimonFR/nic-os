# hosts/rpi5/beaverhabits.nix
#
# BeaverHabits — self-hosted habit tracker (daya0576/beaverhabits), packaged
# natively via the beaverhabits-nix flake (github:nSimonFR/beaverhabits-nix),
# same model as airtrail-nix / sure-nix. Python/NiceGUI app; single gunicorn
# worker; SQLite storage (HABITS_STORAGE=DATABASE) — no external DB.
#
# Memory-constrained RPi5: like airtrail/sure/paperless it sits behind
# systemd-socket-proxyd (hosts/rpi5/lib/socket-activate.nix) — sleeps after 10 min
# idle (~0 RAM at rest, ~100–150 MB awake), wakes on first request.
#
# Three signing secrets (session cookie / JWT / password-reset token) come from
# the agenix env file so they never land in the world-readable Nix store.
{ config, pkgs, lib, tailnetFqdn, ... }:
let
  internalPort = 13342;  # gunicorn bind (real backend, localhost only)
  proxyPort    = 8320;   # socket-activate proxy listen; Tailscale Serve → here
  # External tailnet HTTPS port: declared once in nic.services.beaverhabits.public
  # below, which also derives publicUrl for APP_URL.
in
{
  services.beaverhabits = {
    enable          = true;
    host            = "127.0.0.1";
    port            = internalPort;
    environmentFile = "/run/agenix/beaverhabits-env";  # NICEGUI_STORAGE_SECRET, JWT_SECRET, RESET_PASSWORD_TOKEN_SECRET
    settings = {
      APP_URL = config.nic.services.beaverhabits.public.publicUrl;
      # Single-user instance: don't let anyone else self-register.
      MAX_USER_COUNT = "1";
    };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────────
  # Proxy on :8320 lazily starts beaverhabits.service on first connection and
  # stops it after idleSec. NiceGUI's gunicorn worker binds in ~2–3s; the ready
  # probe hits "/" so the first proxied request doesn't race the bind.
  services.socketActivate.beaverhabits = {
    enable   = true;
    realUnit = "beaverhabits.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString internalPort}";
    idleSec  = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString internalPort}/";
      # Unauthenticated "/" 307-redirects to /login once the worker is up — that
      # redirect is our "server is ready" signal (verified during bring-up).
      expectStatus = 307;
      timeoutSec   = 60;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.beaverhabits = {
    backup        = [ "unit" ];
    backupUnits   = [ "beaverhabits-backup.service" ];   # backups.nix
    heavyUnits    = [ "beaverhabits.service" ];
    heavyPriority = 100;

    # Kept last in Apps so the tile sits at the end of the group.
    public = {
      order   = 60;
      port    = 3650;
      backend = "http://127.0.0.1:${toString proxyPort}";
      tile = {
        name        = "BeaverHabits";
        # BeaverHabits isn't in dashboard-icons, so point at its apple-touch-icon
        # via jsdelivr (pinned tag).
        icon        = "https://cdn.jsdelivr.net/gh/daya0576/beaverhabits@v0.9.1/statics/images/apple-touch-icon.png";
        category    = "Apps";
        description = "Habit tracker";
        # Reads habits.db (JSON blob) directly, so the daily poll never wakes it.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/beaverhabits";
          refreshInterval = 3600000;
          mappings = [
            { field = "habits"; label = "Habits"; format = "number"; }
            { field = "done_today"; label = "Done today"; format = "number"; }
            { field = "checkins"; label = "Check-ins"; format = "number"; }
          ];
        };
      };
    };
  };
}
