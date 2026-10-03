# tailnet-mitm.nix — one transparent mitmproxy for tailnet devices, many targets.
#
# Each target's hostnames are advertised as subnet routes, so the listed clients'
# traffic to them flows through rpi5; their :443 is REDIRECTed to mitmproxy, which
# decrypts only the targets' hosts and runs each target's addon. Clients must trust
# the CA in ${stateDir}/mitmproxy and accept subnet routes.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.tailnet-mitm;
  targets = lib.attrValues cfg.targets;
  # Named after the first target: the clients already trust the CA kept here.
  user = "sumeria-mitm";
  stateDir = "/var/lib/sumeria-mitm";
  v6Hosts = lib.concatMap (t: t.hosts) (lib.filter (t: t.ipv6) targets);
  ipset = "${pkgs.ipset}/bin/ipset";

  # `tailscale set --advertise-routes=` is ABSOLUTE: it replaces the node's whole
  # route list. Advertising only the Lydia IPs therefore withdrew 10.7.0.1/32 and
  # silently killed SideStore refresh (2026-09-14). So this reconciles instead of
  # overwriting: take what the node advertises today, drop the previous run's IPs,
  # add the current ones, and leave every other route alone. The comparison is
  # against live prefs rather than the state file so it also heals the reverse
  # clobber — tailscale-autoconnect runs `tailscale up --advertise-routes=<static
  # list>` on every boot, which drops these IPs.
  routeUpdateScript = pkgs.writeShellApplication {
    name = "tailnet-mitm-route-update";
    runtimeInputs = with pkgs; [ dig gnugrep coreutils jq tailscale ipset ];
    text = ''
      STATE_FILE="${stateDir}/routes.txt"
      V4_HOSTS=(${lib.escapeShellArgs (lib.concatMap (t: t.hosts) targets)})
      V6_HOSTS=(${lib.escapeShellArgs v6Hosts})

      # `|| true` is load-bearing: writeShellApplication sets `-o pipefail`, so an
      # empty dig — DNS not up yet on the boot run — makes `grep` exit 1 and kills
      # the script *at the assignment*, before the guard below. That is how the
      # 2026-09-21 boot left the Lydia routes withdrawn (interception silently
      # down) until the next daily timer, which is exactly what the boot run is
      # supposed to prevent.
      NEW_IPS=$(
        for h in "''${V4_HOSTS[@]}"; do
          dig +short "$h" A | grep -E '^[0-9.]+$' | sed 's|$|/32|' || true
        done
        for h in "''${V6_HOSTS[@]}"; do
          dig +short "$h" AAAA | grep -E '^[0-9a-f:]+$' | grep ':' | sed 's|$|/128|' || true
        done
      )
      NEW_IPS=$(echo "$NEW_IPS" | grep -v '^$' | sort -u || true)
      if [ -z "$NEW_IPS" ]; then
        echo "[tailnet-mitm-route] DNS lookup failed, keeping current routes"
        exit 0
      fi

      # Exit-node advertisement is rendered into AdvertiseRoutes as the two
      # default routes but is a separate pref — never pass it back to --advertise-routes.
      CURRENT=$(tailscale debug prefs \
        | jq -r '.AdvertiseRoutes[]?' \
        | grep -vE '^(0\.0\.0\.0/0|::/0)$' | sort || true)
      # lydia-ip.txt is the pre-tailnet-mitm state file; read once so its IPs get pruned.
      PREV=$(cat "$STATE_FILE" 2>/dev/null || cat "${stateDir}/lydia-ip.txt" 2>/dev/null || true)
      PREV=$(echo "$PREV" | tr ',' '\n' | grep -v '^$' | sort || true)
      OTHERS=$(comm -23 <(echo "$CURRENT") <(echo "$PREV"))
      DESIRED=$(printf '%s\n%s\n' "$OTHERS" "$NEW_IPS" | grep -v '^$' | sort -u)

      if [ "$DESIRED" != "$CURRENT" ]; then
        echo "[tailnet-mitm-route] routes changed: $(echo "$CURRENT" | paste -sd, -) -> $(echo "$DESIRED" | paste -sd, -)"
        tailscale set --advertise-routes="$(echo "$DESIRED" | paste -sd, -)"
      fi
      echo "$NEW_IPS" | paste -sd, - > "$STATE_FILE"

      ipset create -exist tailnet-mitm6 hash:ip family inet6
      ipset flush tailnet-mitm6
      for ip in $(echo "$NEW_IPS" | grep -F ':' | cut -d/ -f1 || true); do
        ipset add -exist tailnet-mitm6 "$ip"
      done
    '';
  };
in
{
  options.services.tailnet-mitm = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 8889;
    };
    clients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Tailscale IPv4s whose :443 through rpi5 is intercepted";
    };
    stateGroup = lib.mkOption {
      type = lib.types.str;
      default = user;
      description = "Group with read access to ${stateDir} (for an addon's output)";
    };
    targets = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          hosts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Hostnames whose IPs are advertised as subnet routes";
          };
          allowHosts = lib.mkOption {
            type = lib.types.str;
            description = "mitmproxy --allow-hosts regex (matched against host:port)";
          };
          addon = lib.mkOption { type = lib.types.str; description = "Addon script path (mitmdump -s)"; };
          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
          ipv6 = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Also route the AAAA records here, only to drop them, so clients fall back to the intercepted IPv4";
          };
        };
      });
    };
  };

  config = lib.mkIf (cfg.targets != { }) {
    users.users.${user} = { isSystemUser = true; group = user; };
    users.groups.${user} = { };

    systemd.tmpfiles.rules = [ "d ${stateDir} 0750 ${user} ${cfg.stateGroup} - -" ];

    systemd.services.tailnet-mitm = {
      description = "Transparent mitmproxy for tailnet clients";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " (
          [
            "${pkgs.mitmproxy}/bin/mitmdump"
            "--mode transparent"
            "-p ${toString cfg.port}"
            "--allow-hosts '${lib.concatMapStringsSep "|" (t: "(${t.allowHosts})") targets}'"
            "--set confdir=${stateDir}/mitmproxy"
            "--set block_global=false"
          ]
          ++ map (t: "-s ${t.addon}") targets
        );
        User = user;
        Group = user;
        Restart = "on-failure";
        RestartSec = "5";
        ReadWritePaths = [ stateDir ];
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        LimitNOFILE = 65536;
      };

      environment = lib.mkMerge (map (t: t.environment) targets ++ [
        # mitmdump's stdout is block-buffered, so with this service's low traffic
        # the journal lagged by *days* — the 2026-09-08 breakage only surfaced in
        # the log when the process was restarted 6 days later. Keep it live.
        { PYTHONUNBUFFERED = "1"; }
      ]);
    };

    # Only traffic to advertised routes reaches rpi5 on tailscale0, so a per-client
    # :443 REDIRECT covers every target. UDP 443 is dropped in mangle PREROUTING
    # (NAT runs before FORWARD) so QUIC falls back to interceptable TCP.
    networking.firewall.extraCommands = lib.mkIf (cfg.clients != [ ]) (
      lib.concatMapStringsSep "\n" (ip: ''
        iptables -t nat -A PREROUTING -i tailscale0 -s ${ip} -p tcp --dport 443 -j REDIRECT --to-port ${toString cfg.port}
        iptables -I FORWARD -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP
        iptables -t mangle -I PREROUTING -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP
      '') cfg.clients
      + lib.optionalString (v6Hosts != [ ]) ''
        ${ipset} create -exist tailnet-mitm6 hash:ip family inet6
        ip6tables -t mangle -I PREROUTING -i tailscale0 -m set --match-set tailnet-mitm6 dst -j DROP
      ''
    );
    networking.firewall.extraStopCommands = lib.mkIf (cfg.clients != [ ]) (
      lib.concatMapStringsSep "\n" (ip: ''
        iptables -t nat -D PREROUTING -i tailscale0 -s ${ip} -p tcp --dport 443 -j REDIRECT --to-port ${toString cfg.port} || true
        iptables -D FORWARD -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP || true
        iptables -t mangle -D PREROUTING -i tailscale0 -s ${ip} -p udp --dport 443 -j DROP || true
      '') cfg.clients
      + lib.optionalString (v6Hosts != [ ]) ''
        ip6tables -t mangle -D PREROUTING -i tailscale0 -m set --match-set tailnet-mitm6 dst -j DROP || true
      ''
    );

    systemd.services.tailnet-mitm-route-update = {
      description = "Advertise tailnet-mitm targets' IPs as subnet routes";
      # Also runs at boot, after tailscale-autoconnect has reset the route list to
      # the static one from configuration.nix — otherwise these routes stay
      # withdrawn until DNS changes, i.e. capture dies silently on every reboot.
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscale-autoconnect.service" ];
      wants = [ "tailscale-autoconnect.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${routeUpdateScript}/bin/tailnet-mitm-route-update";
        ReadWritePaths = [ stateDir ];
      };
    };
    systemd.timers.tailnet-mitm-route-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
      };
    };
  };
}
