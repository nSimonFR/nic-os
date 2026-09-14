{ config, lib, pkgs, ... }:
let
  cfg = config.services.sumeria-mitm;

  # Every hostname the Sumeria app has been observed calling. Matching on the
  # apex covers all of them at once — the app moved api.lydia-app.com ->
  # lc.lydia-app.com on 2026-09-08 and a host-specific match silently stopped
  # intercepting (traffic passed through undecrypted, tokens froze for 6 days).
  apiDomain = "lydia-app.com";
  # Regex for mitmproxy --allow-hosts, which matches against "host:port".
  apiDomainRe = "lydia-app\\.com";

  # Periodically resolve the API host and update the Tailscale subnet route if
  # the IPs changed. Keeps interception working if Sumeria migrates the API.
  # lc.lydia-app.com round-robins across several VIPs, so advertise all of them
  # — picking one with `head -1` would flap with DNS ordering.
  routeUpdateScript = pkgs.writeShellScript "sumeria-route-update" ''
    set -euo pipefail
    STATE_FILE="/var/lib/sumeria-mitm/lydia-ip.txt"
    CURRENT_IPS=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    NEW_IPS=$(${pkgs.dig}/bin/dig +short lc.${apiDomain} \
      | ${pkgs.gnugrep}/bin/grep -E '^[0-9.]+$' | sort | sed 's|$|/32|' | paste -sd, -)
    if [ -z "$NEW_IPS" ]; then
      echo "[sumeria-route] DNS lookup failed, keeping current route"
      exit 0
    fi
    if [ "$NEW_IPS" != "$CURRENT_IPS" ]; then
      echo "[sumeria-route] IPs changed: $CURRENT_IPS -> $NEW_IPS, updating route"
      ${pkgs.tailscale}/bin/tailscale set --advertise-routes="$NEW_IPS"
      echo "$NEW_IPS" > "$STATE_FILE"
    fi
  '';

  # Intercepts requests to lydia-app.com and extracts the three static session
  # headers (auth_token / public_token / access-token) that Sumeria uses instead of OAuth.
  # Tokens are written atomically so the consumer picks them up without a restart.
  # NOTE: these headers are undocumented and were discovered by MITM. Update if auth changes.
  # Only some endpoints carry all three (e.g. /service/accounts/<id>/moneyalerts);
  # most requests have none, so a miss here is normal, not a failure.
  tokenExtractor = pkgs.writeText "sumeria-token-extractor.py" ''
    import json, os
    from mitmproxy import http

    TOKEN_FILE = os.environ["SUMERIA_TOKEN_FILE"]

    class SumeriaTokenExtractor:
        def request(self, flow: http.HTTPFlow):
            # In transparent mode flow.request.host is the IP; use pretty_host (SNI-based)
            host = flow.request.pretty_host
            if "${apiDomain}" not in host:
                return
            h = flow.request.headers
            print(f"[sumeria-mitm] intercepted {host}{flow.request.path} auth={bool(h.get('auth_token'))}")
            if h.get("auth_token") and h.get("public_token") and h.get("access-token"):
                tokens = {
                    "auth_token":   h["auth_token"],
                    "public_token": h["public_token"],
                    "access_token": h["access-token"],
                }
                # Only write if tokens actually changed — avoids spamming the
                # PathModified watcher (and downstream Sure sync) on every request
                try:
                    with open(TOKEN_FILE, "r") as f:
                        existing = json.load(f)
                    if existing == tokens:
                        print(f"[sumeria-mitm] tokens unchanged, skipping write")
                        return
                except (FileNotFoundError, json.JSONDecodeError):
                    pass  # first run or corrupt file — write anyway
                tmp = TOKEN_FILE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(tokens, f, indent=2)
                os.rename(tmp, TOKEN_FILE)
                print(f"[sumeria-mitm] NEW tokens written to {TOKEN_FILE}")

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
          "--allow-hosts ${apiDomainRe}"
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
      # mitmdump's stdout is block-buffered, so with this service's low traffic
      # the journal lagged by *days* — the 2026-09-08 breakage only surfaced in
      # the log when the process was restarted 6 days later. Keep it live.
      environment.PYTHONUNBUFFERED = "1";
    };

    # Redirect HTTPS from subnet-routed / exit-node clients → mitmproxy.
    # With subnet routing for the API's IPs, traffic arrives on tailscale0
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

    # Monitor lc.${apiDomain} DNS and update subnet route if the IPs change
    systemd.services.sumeria-route-update = {
      description = "Update Tailscale subnet route for lc.${apiDomain}";
      serviceConfig = {
        Type      = "oneshot";
        ExecStart = routeUpdateScript;
        ReadWritePaths = [ "/var/lib/sumeria-mitm" ];
      };
    };
    systemd.timers.sumeria-route-update = {
      description = "Daily DNS check for lc.${apiDomain} IP changes";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
      };
    };

  };
}
