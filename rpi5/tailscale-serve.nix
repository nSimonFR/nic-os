{ pkgs, lib, ... }:
let
  # Tailnet-only HTTPS services (tailscale serve).
  # Each entry: { port = external HTTPS port; backend = local HTTP URL; }
  serveEntries = [
    { port = 8080;  backend = "http://127.0.0.1:8080";  } # nginx portal (firefly)
    { port = 8123;  backend = "http://127.0.0.1:8123";  } # home-assistant
    { port = 13333; backend = "http://127.0.0.1:13333"; } # ghostfolio
    { port = 9099;  backend = "http://127.0.0.1:9099";  } # scrutiny (disk health)
    { port = 3000;  backend = "http://127.0.0.1:3000";  } # grafana
    { port = 8085;  backend = "http://127.0.0.1:8085";  } # filebrowser

  ];

  # Publicly-accessible services (tailscale funnel).
  # Each entry: { port = external HTTPS port; backend = local HTTP URL; }
  funnelEntries = [
    { port = 443;  backend = "http://127.0.0.1:18789"; } # openclaw gateway
    { port = 3334; backend = "http://127.0.0.1:3334";  } # voice webhook (Twilio)
  ];

  ts = "${pkgs.tailscale}/bin/tailscale";

  serveUp   = lib.concatMapStringsSep "\n  " (e: "${ts} serve   --bg --https=${toString e.port} ${e.backend}") serveEntries;
  funnelUp  = lib.concatMapStringsSep "\n  " (e: "${ts} funnel  --bg --https=${toString e.port} ${e.backend}") funnelEntries;
  serveDown = lib.concatMapStringsSep "\n  " (e: "${ts} serve  --https=${toString e.port} off || true") serveEntries;
  funnelDown= lib.concatMapStringsSep "\n  " (e: "${ts} funnel --https=${toString e.port} off || true") funnelEntries;
in
{
  systemd.services.tailscale-serve = {
    description = "Tailscale Serve + Funnel";
    after    = [ "network-online.target" "tailscaled.service" "tailscale-autoconnect.service" ];
    wants    = [ "network-online.target" "tailscaled.service" "tailscale-autoconnect.service" ];
    requires = [ "tailscale-autoconnect.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      sleep 2
      ${ts} serve reset || true
      ${serveUp}
      ${funnelUp}
      ${ts} drive share cloud /mnt/cloud || true
    '';
    preStop = ''
      ${serveDown}
      ${funnelDown}
      ${ts} drive unshare cloud || true
    '';
  };
}
