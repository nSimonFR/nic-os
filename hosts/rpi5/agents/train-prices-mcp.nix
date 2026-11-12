# hosts/rpi5/agents/train-prices-mcp.nix
#
# Live train prices (nicos_scripts.trains) as a Streamable HTTP MCP server, for
# Aperture's `trains` connector (aperture-sync.nix). Socket-activated: 0 at rest.
# No authentication — public fare data — and tailnet-only.
{ pkgs, ... }:
let
  internalPort = 13358;
  proxyPort = 8360;
in
{
  systemd.services.train-prices-mcp = {
    description = "Train prices MCP server (Streamable HTTP)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      TRAINS_MCP_HOST = "127.0.0.1";
      TRAINS_MCP_PORT = toString internalPort;
    };
    serviceConfig = {
      ExecStart = "${pkgs.nicos-scripts}/bin/train-prices-mcp-http";
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  services.socketActivate.train-prices-mcp = {
    enable = true;
    realUnit = "train-prices-mcp.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    readyProbe.url = "http://127.0.0.1:${toString internalPort}/health";
  };

  nic.services.train-prices-mcp = {
    backup = [ "none" ];
    backupNote = "stateless — fares are fetched live";
    public = {
      order = 175;
      port = 3930;
      backend = "http://127.0.0.1:${toString proxyPort}";
      funnel = false;
      authenticated = false;
    };
  };
}
