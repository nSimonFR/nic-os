{ config, lib, pkgs, ... }:
let
  cfg = config.services.sumeria-mitm;

  # Periodically resolve api.lydia-app.com and update the Tailscale subnet
  # route if the IP changed. Keeps the MITM interception working even if
  # Lydia migrates their API to a different IP.
  routeUpdateScript = pkgs.writeShellScript "sumeria-route-update" ''
    set -euo pipefail
    STATE_FILE="/var/lib/sumeria-mitm/lydia-ip.txt"
    CURRENT_IP=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    NEW_IP=$(${pkgs.dig}/bin/dig +short api.lydia-app.com | head -1)
    if [ -z "$NEW_IP" ]; then
      echo "[sumeria-route] DNS lookup failed, keeping current route"
      exit 0
    fi
    if [ "$NEW_IP" != "$CURRENT_IP" ]; then
      echo "[sumeria-route] IP changed: $CURRENT_IP -> $NEW_IP, updating route"
      ${pkgs.tailscale}/bin/tailscale set --advertise-routes="$NEW_IP/32"
      echo "$NEW_IP" > "$STATE_FILE"
    fi
  '';

  # Intercepts requests to api.lydia-app.com and extracts the three static session
  # headers (auth_token / public_token / access-token) that Sumeria uses instead of OAuth.
  # Tokens are written atomically so the consumer picks them up without a restart.
  # NOTE: these headers are undocumented and were discovered by MITM. Update if auth changes.
  tokenExtractor = pkgs.writeText "sumeria-token-extractor.py" ''
    import json, os
    from mitmproxy import http

    TOKEN_FILE = os.environ["SUMERIA_TOKEN_FILE"]

    class SumeriaTokenExtractor:
        def request(self, flow: http.HTTPFlow):
            # In transparent mode flow.request.host is the IP; use pretty_host (SNI-based)
            host = flow.request.pretty_host
            if "api.lydia-app.com" not in host:
                return
            h = flow.request.headers
            print(f"[sumeria-mitm] intercepted {host}{flow.request.path} auth={bool(h.get('auth_token'))}")
            if h.get("auth_token") and h.get("public_token") and h.get("access-token"):
                tokens = {
                    "auth_token":   h["auth_token"],
                    "public_token": h["public_token"],
                    "access_token": h["access-token"],
                }
                tmp = TOKEN_FILE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(tokens, f, indent=2)
                os.rename(tmp, TOKEN_FILE)
                print(f"[sumeria-mitm] tokens written to {TOKEN_FILE}")

    addons = [SumeriaTokenExtractor()]
  '';
in
{
  options.services.sumeria-mitm = {
    enable = lib.mkEnableOption "Sumeria token extractor (mitmproxy transparent proxy)";

    port = lib.mkOption {
      type        = lib.types.port;
      default     = 8889;
      description = "Port for the mitmproxy transparent proxy";
    };

    tokenFile = lib.mkOption {
      type        = lib.types.str;
      default     = "/var/lib/sumeria-mitm/tokens.json";
      description = "Path where captured Sumeria tokens are written";
    };

    tokenFileGroup = lib.mkOption {
      type        = lib.types.str;
      default     = "sumeria-mitm";
      description = "Group that gets read access to the token file (set to consumer's group)";
    };

    exitNodeClients = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [];
      description = "Tailscale IPs of devices using the RPi5 as exit node (HTTPS intercepted)";
      example     = [ "100.112.22.60" ];
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.sumeria-mitm  = { isSystemUser = true; group = "sumeria-mitm"; };
    users.groups.sumeria-mitm = {};

    systemd.tmpfiles.rules = [
      "d /var/lib/sumeria-mitm 0750 sumeria-mitm ${cfg.tokenFileGroup} - -"
    ];

    # Prerequisites:
    # - mitmproxy CA must be installed + trusted on the iPhone (visit http://mitm.it via proxy)
    # - exit node must be approved in Tailscale admin console
    systemd.services.sumeria-mitm = {
      description = "Sumeria token extractor (mitmproxy transparent)";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.mitmproxy}/bin/mitmdump"
          "--mode transparent"
          "-p ${toString cfg.port}"
          "--allow-hosts api\\.lydia-app\\.com"
          "--set confdir=/var/lib/sumeria-mitm/mitmproxy"
          "--set block_global=false"
          "-s ${tokenExtractor}"
        ];
        User                = "sumeria-mitm";
        Group               = "sumeria-mitm";
        Restart             = "on-failure";
        RestartSec          = "5";
        ReadWritePaths      = [ "/var/lib/sumeria-mitm" ];
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        LimitNOFILE         = 65536;
      };

      environment.SUMERIA_TOKEN_FILE = cfg.tokenFile;
    };

    # Redirect HTTPS from subnet-routed / exit-node clients → mitmproxy.
    # With subnet routing for api.lydia-app.com's IP, traffic arrives on tailscale0
    # with a public destination (not RPi5's own Tailscale IP), so no conflict with Serve.
    # Also drop UDP 443 (QUIC/HTTP3) so apps fall back to TCP (HTTP2) which mitmproxy can intercept.
    networking.firewall.extraCommands = lib.mkIf (cfg.exitNodeClients != []) (
      lib.concatMapStringsSep "\n" (ip: ''
        iptables -t nat -A PREROUTING -i tailscale0 -s ${ip} -p tcp --dport 443 -j REDIRECT --to-port ${toString cfg.port}
        iptables -I FORWARD -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP
        iptables -t mangle -I PREROUTING -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP
      '') cfg.exitNodeClients
    );
    networking.firewall.extraStopCommands = lib.mkIf (cfg.exitNodeClients != []) (
      lib.concatMapStringsSep "\n" (ip: ''
        iptables -t nat -D PREROUTING -i tailscale0 -s ${ip} -p tcp --dport 443 -j REDIRECT --to-port ${toString cfg.port} || true
        iptables -D FORWARD -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP || true
        iptables -t mangle -D PREROUTING -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP || true
      '') cfg.exitNodeClients
    );

    # Monitor api.lydia-app.com DNS and update subnet route if IP changes
    systemd.services.sumeria-route-update = {
      description = "Update Tailscale subnet route for api.lydia-app.com";
      serviceConfig = {
        Type      = "oneshot";
        ExecStart = routeUpdateScript;
        ReadWritePaths = [ "/var/lib/sumeria-mitm" ];
      };
    };
    systemd.timers.sumeria-route-update = {
      description = "Daily DNS check for api.lydia-app.com IP changes";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
      };
    };

  };
}
