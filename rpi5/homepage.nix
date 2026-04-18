{ lib, tailnetFqdn, voiceWebhookPort, ... }:
let
  registry = import ./services-registry.nix { inherit voiceWebhookPort; };
  allEntries = registry.serveEntries ++ registry.funnelEntries;

  # Exclude Homepage itself from its own dashboard
  visibleEntries = builtins.filter (e: e.name != "Homepage") allEntries;

  # Ordered category list (controls display order on the dashboard)
  categoryOrder = [
    "Home"
    "Media"
    "AI / LLM"
    "Dev Tools"
    "Finance"
    "Monitoring"
    "Infrastructure"
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
      layout = builtins.listToAttrs (lib.imap0 (i: cat: {
        name = cat;
        value = {
          style = "row";
          columns = 4;
        };
      }) categoryOrder);
    };

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
