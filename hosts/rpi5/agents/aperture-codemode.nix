# One Code Mode MCP server (pkgs/agents/aperture-codemode) shared by every agent on the
# Pi: Claude Code sessions (hosts/rpi5/home.nix) and Hermes (hermes/hermes.nix). As a
# stdio server each session started its own Node copy (~60 MiB each, five at once under
# T3); this is one process, one Aperture connection and one tool cache.
# Socket-activated: 0 at rest. Stateless HTTP, so an idle exit strands no client.
# Loopback-only; Aperture already trusts any process on this node (tailnet identity).
{
  lib,
  pkgs,
  apertureUrl,
  username,
  ...
}:
let
  internalPort = 13370;
  proxyPort = 8480;
in
{
  systemd.services.aperture-codemode = {
    description = "Code Mode MCP server over Aperture, shared by the Pi's agents";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      APERTURE_MCP_URL = "${apertureUrl}/v1/mcp";
      CODEMODE_EXCLUDE = lib.concatStringsSep "," (import ../../../shared/aperture-send-tools.nix);
      CODEMODE_HTTP_HOST = "127.0.0.1";
      CODEMODE_HTTP_PORT = toString internalPort;
      # The proxy forwards the stream unchanged, so clients' Host names the proxy port.
      CODEMODE_HTTP_ALLOWED_HOSTS = "127.0.0.1:${toString proxyPort}";
      # Readable by the agents (nsimon) when debugging a run.
      CODEMODE_LOG = "/var/lib/aperture-codemode/calls.jsonl";
    };
    serviceConfig = {
      ExecStart = lib.getExe pkgs.aperture-codemode;
      User = username;
      StateDirectory = "aperture-codemode";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  services.socketActivate.aperture-codemode = {
    enable = true;
    realUnit = "aperture-codemode.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    # Sessions start all day: a long idle window keeps the tool cache warm between them.
    idleSec = 1800;
    readyProbe.url = "http://127.0.0.1:${toString internalPort}/health";
  };

  nic.services.aperture-codemode = {
    backup = [ "none" ];
    backupNote = "stateless — calls.jsonl is a rotating debug log";
  };
}
