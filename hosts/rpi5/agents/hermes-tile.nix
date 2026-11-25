# Hermes's homepage tile. Hermes itself is a home-manager user unit
# (hermes/hermes.nix), and `nic.externalTiles` is a NixOS option, so the tile
# lives here. Backend health tile, no link: Hermes is driven from Telegram. A
# cron job that errors or gets auto-paused is otherwise silent — see fetch_hermes.
_: {
  nic.externalTiles = [
    {
      order = 340;
      tile = {
        name = "Hermes";
        icon = "mdi-robot-happy-outline";
        category = "Backend";
        description = "Agent cron jobs (all profiles)";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/hermes";
          refreshInterval = 3600000;
          mappings = [
            {
              field = "jobs";
              label = "Jobs";
              format = "number";
            }
            {
              field = "paused";
              label = "Paused";
              format = "number";
            }
            {
              field = "failing";
              label = "Failing";
              format = "number";
            }
          ];
        };
      };
    }
  ];
}
