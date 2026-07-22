# rpi5/ryot-connectors.nix
#
# Two small "pull" connectors that feed Ryot domains it has no native integration
# for, via Ryot's Generic JSON sink (a per-integration webhook, /ryot/_i/<slug>,
# that accepts a `CompleteExport` body — see rpi5/ryot.nix for the proxy route).
#
#   * steam-to-ryot.service  — Steam owned games + playtime → a "Steam" collection
#     of IGDB-resolved games, with best-effort playtime "seens". Daily.
#   * spotify-to-ryot.service — Spotify recently-played → music listens. Hourly.
#
# Both are stdlib-Python (scripts/), run as the unprivileged `ryot-connector`
# user, keep idempotency state under /var/lib/ryot-connectors (StateDirectory),
# and read their secrets from agenix EnvironmentFiles. Pattern mirrors the
# ryot-plex-import oneshot+timer in rpi5/ryot.nix and the scale-to-ryot shim.
#
# IMPORTANT — the sink resolves metadata synchronously through Ryot's OWN
# providers, so ryot-env must carry VIDEO_GAMES_TWITCH_CLIENT_ID/SECRET (IGDB,
# for Steam) and MUSIC_SPOTIFY_CLIENT_ID/SECRET (for Spotify), or every item 401s
# exactly like the documented TMDB case. Secrets declared in rpi5/secrets.nix:
#   * steam-connector-env   — STEAM_API_KEY, STEAM_ID64, TWITCH_CLIENT_ID,
#                             TWITCH_CLIENT_SECRET, RYOT_WEBHOOK_URL
#   * spotify-connector-env — SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET,
#                             SPOTIFY_REFRESH_TOKEN, RYOT_WEBHOOK_URL
{ config, pkgs, lib, ... }:
let
  stateDir = "/var/lib/ryot-connectors";

  # A timer-driven oneshot that runs one stdlib-Python connector script.
  # No wantedBy: the timer (below) is the only thing that should start it — we
  # don't want a run on every boot/activation (and a mid-rebuild backend restart
  # would 502 it).
  connector = { script, envFile }: {
    after = [ "ryot-proxy.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.python3 ];
    environment.STATE_DIR = stateDir;
    serviceConfig = {
      Type = "oneshot";
      User = "ryot-connector";
      Group = "ryot-connector";
      StateDirectory = "ryot-connectors"; # creates + owns /var/lib/ryot-connectors
      EnvironmentFile = envFile;
      ExecStart = "${pkgs.python3}/bin/python3 ${script}";
    };
  };
in
{
  users.users.ryot-connector = {
    isSystemUser = true;
    group = "ryot-connector";
  };
  users.groups.ryot-connector = { };

  systemd.services.steam-to-ryot = connector {
    script = ./scripts/steam-to-ryot.py;
    envFile = "/run/agenix/steam-connector-env";
  } // { description = "Steam library + playtime → Ryot"; };

  systemd.services.spotify-to-ryot = connector {
    script = ./scripts/spotify-to-ryot.py;
    envFile = "/run/agenix/spotify-connector-env";
  } // { description = "Spotify recently-played → Ryot"; };

  systemd.timers.steam-to-ryot = {
    description = "Daily Steam → Ryot sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:50:00"; # after the Plex import (04:40) + backup window
      Persistent = true;             # catch up a missed run if the Pi was off
    };
  };

  systemd.timers.spotify-to-ryot = {
    description = "Hourly Spotify → Ryot sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:17:00"; # hourly, off the :00 mark
      Persistent = true;
    };
  };
}
