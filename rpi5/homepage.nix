{ lib, tailnetFqdn, voiceWebhookPort, ... }:
let
  registry = import ./services-registry.nix { inherit voiceWebhookPort; };
  allEntries = registry.serveEntries ++ registry.funnelEntries;

  # Hide Homepage and Infrastructure from the dashboard
  visibleEntries = builtins.filter (e: e.name != "Homepage" && e.category != "Infrastructure") allEntries;

  # Explicit tile ordering per category (entries not listed here appear at the end)
  tileOrder = {
    "Apps" = [ "AFFiNE" "Immich" "Sure" "Open WebUI" ];
    "Services" = [ "Vaultwarden" "Home Assistant" "Filebrowser" "Forgejo" ];
  };

  sortEntries = cat: entries:
    let
      order = tileOrder.${cat} or [];
      indexOf = name: let idx = lib.lists.findFirstIndex (n: n == name) (builtins.length order) order; in idx;
    in builtins.sort (a: b: indexOf a.name < indexOf b.name) entries;

  # Ordered category list (controls display order on the dashboard)
  categoryOrder = [
    "Apps"
    "Services"
    "Monitoring"
    "Backend"
  ];

  entriesForCategory = cat:
    builtins.filter (e: e.category == cat) visibleEntries;

  # Build the services list: one attrset per category, each containing service tiles
  servicesByCategory = builtins.filter (group: group != null) (
    map (cat:
      let entries = sortEntries cat (entriesForCategory cat);
      in if entries == [] then null
      else {
        "${cat}" = map (e: {
          "${e.name}" = {
            icon = e.icon;
            href = "https://${tailnetFqdn}:${toString e.port}";
            inherit (e) description;
            siteMonitor = "https://${tailnetFqdn}:${toString e.port}";
          };
        }) entries;
      }
    ) categoryOrder
  );
in
{
  # Bind to localhost only — Tailscale Serve proxies from the tailnet interface
  # and would conflict on 0.0.0.0:8082.
  systemd.services.homepage-dashboard.environment.HOSTNAME = "127.0.0.1";

  services.homepage-dashboard = {
    enable = true;
    listenPort = 8082;
    allowedHosts = lib.concatStringsSep "," [
      "localhost:8082"
      "127.0.0.1:8082"
      "${tailnetFqdn}:8082"
    ];

    settings = {
      title = "nic-os";
      favicon = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/nixos.svg";
      headerStyle = "clean";
      # List format preserves display order (Nix attrsets sort alphabetically)
      layout = [
        { "Quick Links" = { style = "row"; columns = 3; header = false; }; }
        { "Apps"        = { style = "row"; columns = 4; }; }
        { "Services"    = { style = "row"; columns = 4; }; }
        { "Monitoring"  = { style = "row"; columns = 4; }; }
        { "Backend"     = { style = "row"; columns = 4; }; }
      ];
    };

    bookmarks = [
      {
        "Quick Links" = [
          { "YouTube" = [{ icon = "youtube.svg"; href = "https://www.youtube.com/"; }]; }
          { "GitHub Notifications" = [{ icon = "github.svg"; href = "https://github.com/notifications"; }]; }
          { "IT Tools" = [{ icon = "si-hackthebox"; href = "https://it-tools.tech/"; }]; }
        ];
      }
    ];

    services = servicesByCategory;

    widgets = [
      {
        resources = {
          cpu = true;
          memory = true;
          disk = "/";
        };
      }
      {
        search = {
          provider = "google";
          target = "_blank";
        };
      }
    ];
  };
}
