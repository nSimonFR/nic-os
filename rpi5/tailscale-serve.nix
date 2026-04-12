{ pkgs, lib, tailnetFqdn, voiceWebhookPort, ... }:
let
  # Tailnet-only HTTPS services (tailscale serve).
  # Each entry: { port = external HTTPS port; backend = local HTTP URL; }
  serveEntries = [
    { port = 8123;  backend = "http://127.0.0.1:8123";  } # home-assistant
    { port = 9099;  backend = "http://127.0.0.1:9099";  } # scrutiny (disk health)
    { port = 3000;  backend = "http://127.0.0.1:3000";  } # grafana
    { port = 8085;  backend = "http://127.0.0.1:8085";  } # filebrowser
    { port = 443;   backend = "http://127.0.0.1:18789"; } # openclaw gateway (tailnet only)
    { port = 3333;  backend = "http://127.0.0.1:13334"; } # sure (personal finance)
    { port = 4040;  backend = "http://127.0.0.1:4040";  } # openai-codex proxy
    { port = 8222;  backend = "http://127.0.0.1:8222";  } # vaultwarden (bitwarden)
    { port = 3010;  backend = "http://127.0.0.1:3010";  } # affine
  ];

  # Publicly-accessible services (tailscale funnel).
  # Each entry: { port = external HTTPS port; backend = local HTTP URL; }
  funnelEntries = [
    { port = voiceWebhookPort; backend = "http://127.0.0.1:${toString voiceWebhookPort}"; } # voice webhook (Twilio inbound)
    { port = 10000; backend = "http://127.0.0.1:2283"; } # immich photos (public)
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
      ${ts} drive share cloud /mnt/data/cloud || true
    '';
    preStop = ''
      ${serveDown}
      ${funnelDown}
      ${ts} drive unshare cloud || true
    '';
  };
}
