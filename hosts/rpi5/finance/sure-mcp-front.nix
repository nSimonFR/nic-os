# sure-mcp-front — Sure's MCP tool list, served while Sure sleeps.
#
# A Rails cold start is 14–30 s and Aperture does not wait that long on a
# `tools/list`, so Sure's tools went missing for any client that connected while
# it slept. The front (nicos_scripts.mcpfront) caches `initialize`/`tools/list`
# and only wakes Sure for a tool call. Socket-activated too: 0 at rest.
{
  config,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  internalPort = 13359;
  proxyPort = 8372;
  sureWake = 13334; # Sure's socket proxy (sure.nix)
  sureDirect = 13335; # Puma itself: refused while asleep
in
{
  systemd.services.sure-mcp-front = {
    description = "Sure MCP catalog cache";
    environment = {
      MCP_FRONT_PORT = toString internalPort;
      MCP_FRONT_WAKE_URL = "http://127.0.0.1:${toString sureWake}/sure/mcp";
      MCP_FRONT_DIRECT_URL = "http://127.0.0.1:${toString sureDirect}/sure/mcp";
      MCP_FRONT_CACHE = "/var/lib/sure-mcp-front/catalog.json";
      MCP_FRONT_TOKEN_VAR = "MCP_API_TOKEN";
    };
    serviceConfig = {
      ExecStart = "${pkgs.nicos-scripts}/bin/mcp-catalog-front";
      EnvironmentFile = config.age.secrets.sure-mcp-env.path;
      DynamicUser = true;
      StateDirectory = "sure-mcp-front";
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  services.socketActivate.sure-mcp-front = {
    enable = true;
    realUnit = "sure-mcp-front.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    readyProbe.url = "http://127.0.0.1:${toString internalPort}/health";
  };

  # Aperture's `sure` connector URL; the 443 mux still goes to Sure directly.
  # Exact match, so it wins over the vhost's `/sure` prefix.
  services.nginx.virtualHosts."sure-root".locations."= /sure/mcp".extraConfig = ''
    proxy_pass http://127.0.0.1:${toString proxyPort};
    proxy_set_header Host ${tailnetFqdn}:${toString config.nic.services.sure-root.public.port};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_read_timeout 300s;
  '';
}
