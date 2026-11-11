# hosts/rpi5/media/ryot-connectors.nix
#
# Pull connectors feeding Ryot V2 (hosts/rpi5/media/ryot.nix) through its REST API:
#
#   * spotify-to-ryot — recently-played → music completes at Spotify's played_at. Hourly.
#   * steam-to-ryot   — one game complete per play session (presence + playtime growth). Every 5 min.
#   * plex-to-ryot    — Plex views since the last run → movie / episode / anime completes. Hourly.
#
# V2's own Spotify and Plex yanks are deliberately unused: Spotify's polls with an
# `after=` cursor (drops plays that sync late from an offline phone), and Plex's
# walks every library item one sandbox step at a time and files the Anime library
# as TV shows.
#
# The API key comes from ryot-bootstrap (/var/lib/ryot-v2/secrets/api.env); the connectors' own
# credentials stay in agenix. Code: the nicos-scripts package, one console script each.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  stateDir = "/var/lib/ryot-connectors";
  secretsEnv = "/var/lib/ryot-v2/secrets/api.env";

  # No wantedBy: only the timer starts it, not every activation.
  connector = { exe, envFiles }: {
    after = [
      "ryot-bootstrap.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    environment = {
      STATE_DIR = stateDir;
      RYOT_URL = "http://127.0.0.1:13350";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "ryot-connector";
      Group = "ryot-connector";
      SupplementaryGroups = [ "ryot-api" ];
      StateDirectory = "ryot-connectors";
      EnvironmentFile = envFiles ++ [ secretsEnv ];
      ExecStart = "${pkgs.nicos-scripts}/bin/${exe}";
    };
  };

  timer = description: onCalendar: {
    inherit description;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = onCalendar;
      Persistent = true;
    };
  };
in
{
  users.users.ryot-connector = {
    isSystemUser = true;
    group = "ryot-connector";
  };
  users.groups.ryot-connector = { };

  systemd.services.spotify-to-ryot =
    connector {
      exe = "spotify-to-ryot";
      envFiles = [ "/run/agenix/spotify-connector-env" ];
    }
    // {
      description = "Spotify recently-played → Ryot";
    };

  systemd.services.steam-to-ryot =
    connector {
      exe = "steam-to-ryot";
      envFiles = [ "/run/agenix/steam-connector-env" ];
    }
    // {
      description = "Steam playtime → Ryot";
    };

  systemd.services.plex-to-ryot =
    connector {
      exe = "plex-to-ryot";
      envFiles = [ "/run/agenix/ryot-import-env" ]; # PLEX_IMPORT_SERVERS
    }
    // {
      description = "Plex watch history → Ryot";
    };

  # Spotify exposes only the last 50 plays, so hourly keeps well inside the window.
  systemd.timers.spotify-to-ryot = timer "Hourly Spotify → Ryot" "*-*-* *:17:00";
  # A session is seen through presence, so its end is known to within 5 min.
  systemd.timers.steam-to-ryot = timer "Steam sessions → Ryot" "*:0/5";
  systemd.timers.plex-to-ryot = timer "Hourly Plex → Ryot" "*-*-* *:37:00";
}
