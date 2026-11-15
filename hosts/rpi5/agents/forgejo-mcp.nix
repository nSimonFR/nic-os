# Forgejo as a Streamable HTTP MCP server, for Aperture's `forgejo` connector
# (aperture-sync.nix). Passthrough auth: each request's bearer is the caller's
# own Forgejo token, so this unit holds none. Socket-activated: 0 at rest.
{ unstablePkgs, tailnetFqdn, ... }:
let
  internalPort = 13359;
  proxyPort = 8390;
  publicPort = 3940;
  # The socket-activate proxy in forgejo.nix: a request here wakes Forgejo.
  forgejoUrl = "http://127.0.0.1:3100";
in
{
  systemd.services.forgejo-mcp = {
    description = "Forgejo MCP server (Streamable HTTP)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      # Exits at start unless Forgejo answers /api/v1/version.
      ExecStart = toString [
        "${unstablePkgs.forgejo-mcp}/bin/forgejo-mcp"
        "-t http"
        "-host 127.0.0.1"
        "-http-port ${toString internalPort}"
        "-url ${forgejoUrl}"
        # Tailscale Serve keeps the tailnet Host; anything else is a 403.
        "-allowed-hosts ${tailnetFqdn}:${toString publicPort},${tailnetFqdn}"
      ];
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  services.socketActivate.forgejo-mcp = {
    enable = true;
    realUnit = "forgejo-mcp.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    # No unauthenticated route: a 401 means it is up. Covers waking Forgejo too.
    readyProbe = {
      url = "http://127.0.0.1:${toString internalPort}/health";
      expectStatus = 401;
      timeoutSec = 120;
    };
  };

  nic.services.forgejo-mcp = {
    backup = [ "none" ];
    backupNote = "stateless — proxies the Forgejo API";
    public = {
      order = 176;
      port = publicPort;
      backend = "http://127.0.0.1:${toString proxyPort}";
      funnel = false;
      # Every request needs a Forgejo token.
      authenticated = true;
    };
  };
}
