# Nico's bridged chats (nicos_scripts.messaging.mcp) as a Streamable HTTP MCP
# server, for Aperture's `messaging` connector (agents/aperture-sync.nix).
# Bearer-protected (token from agents/mcp-bridges.nix). Socket-activated.
{ pkgs, tailnetFqdn, ... }:
let
  internalPort = 13364;
  proxyPort = 8420;
in
{
  systemd.services.messaging-mcp = {
    description = "Messaging MCP server (Streamable HTTP)";
    after = [
      "network-online.target"
      "mcp-tokens.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "mcp-tokens.service" ];
    environment = {
      MATRIX_USER_ID = "@nico:${tailnetFqdn}";
      MESSAGING_MCP_HOST = "127.0.0.1";
      MESSAGING_MCP_PORT = toString internalPort;
    };
    serviceConfig = {
      ExecStart = "${pkgs.nicos-scripts}/bin/messaging-mcp";
      DynamicUser = true;
      # Reads the double-puppet token (bridges.nix).
      SupplementaryGroups = [ "matrix-mcp" ];
      LoadCredential = [ "token:/var/lib/mcp-tokens/messaging" ];
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  services.socketActivate.messaging-mcp = {
    enable = true;
    realUnit = "messaging-mcp.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    readyProbe.url = "http://127.0.0.1:${toString internalPort}/health";
  };

  nic.services.messaging-mcp = {
    backup = [ "none" ];
    backupNote = "stateless — reads the Matrix homeserver live";
    public = {
      order = 180;
      port = 4060;
      backend = "http://127.0.0.1:${toString proxyPort}";
      funnel = false;
      authenticated = true;
    };
  };
}
