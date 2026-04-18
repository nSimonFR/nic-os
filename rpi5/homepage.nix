{ lib, tailnetFqdn, voiceWebhookPort, ... }:
let
  registry = import ./services-registry.nix { inherit voiceWebhookPort; };
  allEntries = registry.serveEntries ++ registry.funnelEntries;

  # Hide Homepage and Infrastructure from the dashboard
  visibleEntries = builtins.filter (e: e.name != "Homepage" && e.category != "Infrastructure") allEntries;

  # Ordered category list (controls display order on the dashboard)
  categoryOrder = [
    "Services"
    "Monitoring"
    "Backend"
  ];

  entriesForCategory = cat:
    builtins.filter (e: e.category == cat) visibleEntries;

  # Build the services list: one attrset per category, each containing service tiles
  servicesByCategory = builtins.filter (group: group != null) (
    map (cat:
      let entries = entriesForCategory cat;
      in if entries == [] then null
      else {
        "${cat}" = map (e: {
          "${e.name}" = {
            icon = "${e.icon}.svg";
            href = "https://${tailnetFqdn}:${toString e.port}";
            inherit (e) description;
            ping = "https://${tailnetFqdn}:${toString e.port}";
          };
        }) entries;
      }
    ) categoryOrder
  );
in
{
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
      layout = builtins.listToAttrs (map (cat: {
        name = cat;
        value = {
          style = "row";
          columns = 4;
        };
      }) categoryOrder);
    };

    bookmarks = [
      {
        "Quick Links" = [
          { "IT Tools" = [{ icon = "mdi-toolbox.svg"; href = "https://it-tools.tech/"; }]; }
          { "GitHub Notifications" = [{ icon = "github.svg"; href = "https://github.com/notifications"; }]; }
          { "YouTube" = [{ icon = "youtube.svg"; href = "https://www.youtube.com/"; }]; }
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
