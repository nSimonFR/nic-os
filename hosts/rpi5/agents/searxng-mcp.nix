# SearXNG search as a Streamable HTTP MCP server (ihor-sokoliuk/mcp-searxng), for
# Aperture's `searxng` connector (aperture-sync.nix). Socket-activated: 0 at rest.
# No authentication, like searxng itself: tailnet-only. `web_url_read` refuses
# private/internal URLs (MCP_HTTP_ALLOW_PRIVATE_URLS stays unset).
{ unstablePkgs, ... }:
let
  internalPort = 13360;
  proxyPort = 8400;
in
{
  systemd.services.searxng-mcp = {
    description = "SearXNG MCP server (Streamable HTTP)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      # searxng's socket-activate proxy (searxng.nix): a search wakes it.
      SEARXNG_URL = "http://127.0.0.1:8380";
      MCP_HTTP_HOST = "127.0.0.1";
      MCP_HTTP_PORT = toString internalPort;
      MCP_HTTP_STATELESS = "true";
    };
    serviceConfig = {
      ExecStart = "${unstablePkgs.mcp-searxng}/bin/mcp-searxng";
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  services.socketActivate.searxng-mcp = {
    enable = true;
    realUnit = "searxng-mcp.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    readyProbe.url = "http://127.0.0.1:${toString internalPort}/health";
  };

  nic.services.searxng-mcp = {
    backup = [ "none" ];
    backupNote = "stateless — queries searxng live";
    public = {
      order = 177;
      port = 3950;
      backend = "http://127.0.0.1:${toString proxyPort}";
      funnel = false;
      authenticated = false;
    };
  };
}
