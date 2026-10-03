# openrouter-mitm.nix — serve tailnet apps' openrouter.ai API calls from tiny-llm-gate.
#
# Same transport as sumeria-mitm.nix: openrouter.ai's IPs are advertised as subnet
# routes, the listed clients' :443 to those IPs is REDIRECTed to a transparent
# mitmproxy, and only the openrouter.ai SNI is decrypted. The addon
# (nicos_scripts/mitm/openrouter.py) sends the API paths the gate serves to the
# gate and lets everything else reach the real site.
#
# Client prerequisites: trust the mitmproxy CA (the Sumeria one, shared below) and
# accept subnet routes; the routes must be approved in the Tailscale admin console.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.openrouter-mitm;
  stateDir = "/var/lib/openrouter-mitm";

  routeUpdateScript = import ./lib/tailnet-routes.nix { inherit pkgs; } {
    name = "openrouter";
    hosts = [ "openrouter.ai" ];
    stateFile = "${stateDir}/routes.txt";
    ipv6 = true;
    ipset4 = "openrouter4";
    ipset6 = "openrouter6";
  };

  addon = "${pkgs.nicos-scripts}/${pkgs.python3.sitePackages}/nicos_scripts/mitm/openrouter.py";

  ipset = "${pkgs.ipset}/bin/ipset";
  # -I, not -A: these must match before sumeria-mitm's catch-all :443 REDIRECT for
  # the same client.
  #
  # IPv6 is routed here only to be dropped, so happy-eyeballs settles on IPv4
  # (which is intercepted) instead of reaching openrouter.ai directly.
  rules = op:
    lib.concatMap (ip: [
      "iptables -t nat ${op} PREROUTING -i tailscale0 -s ${ip} -m set --match-set openrouter4 dst -p tcp --dport 443 -j REDIRECT --to-port ${toString cfg.port}"
      "iptables -t mangle ${op} PREROUTING -i tailscale0 -s ${ip} -m set --match-set openrouter4 dst -p udp --dport 443 -j DROP"
    ]) cfg.clients
    ++ [ "ip6tables -t mangle ${op} PREROUTING -i tailscale0 -m set --match-set openrouter6 dst -j DROP" ];
in
{
  options.services.openrouter-mitm = {
    enable = lib.mkEnableOption "openrouter.ai → tiny-llm-gate interception (mitmproxy transparent)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8890;
      description = "Port of the transparent mitmproxy";
    };

    clients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Tailscale IPv4s whose openrouter.ai traffic is intercepted";
      example = [ "100.112.22.60" ];
    };

    gatePort = lib.mkOption {
      type = lib.types.port;
      default = 4001;
      description = "tiny-llm-gate port on 127.0.0.1";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.openrouter-mitm = { isSystemUser = true; group = "openrouter-mitm"; };
    users.groups.openrouter-mitm = { };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 openrouter-mitm openrouter-mitm - -"
      "d ${stateDir}/mitmproxy 0700 openrouter-mitm openrouter-mitm - -"
    ];

    systemd.services.openrouter-mitm = {
      description = "openrouter.ai → tiny-llm-gate (mitmproxy transparent)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "sumeria-mitm.service" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        # The clients already trust Sumeria's CA; fail rather than mint a new one.
        ExecStartPre = [
          "+${pkgs.coreutils}/bin/install -m 0600 -o openrouter-mitm -g openrouter-mitm /var/lib/sumeria-mitm/mitmproxy/mitmproxy-ca.pem ${stateDir}/mitmproxy/mitmproxy-ca.pem"
          "+${pkgs.coreutils}/bin/install -m 0644 -o openrouter-mitm -g openrouter-mitm /var/lib/sumeria-mitm/mitmproxy/mitmproxy-ca-cert.pem ${stateDir}/mitmproxy/mitmproxy-ca-cert.pem"
        ];
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.mitmproxy}/bin/mitmdump"
          "--mode transparent"
          "-p ${toString cfg.port}"
          "--allow-hosts '^openrouter\\.ai:'"
          "--set confdir=${stateDir}/mitmproxy"
          "--set block_global=false"
          "-s ${addon}"
          "--set gate_port=${toString cfg.gatePort}"
        ];
        User = "openrouter-mitm";
        Group = "openrouter-mitm";
        Restart = "always";
        RestartSec = "5";
        ReadWritePaths = [ stateDir ];
        LimitNOFILE = 65536;
      };
      # mitmdump's stdout is block-buffered; see sumeria-mitm.nix.
      environment.PYTHONUNBUFFERED = "1";
    };

    # The sets must exist before a rule references them; the reconciler fills them.
    networking.firewall.extraCommands = lib.mkIf (cfg.clients != [ ]) ''
      ${ipset} create -exist openrouter4 hash:ip family inet
      ${ipset} create -exist openrouter6 hash:ip family inet6
      ${lib.concatStringsSep "\n" (rules "-I")}
    '';
    networking.firewall.extraStopCommands = lib.mkIf (cfg.clients != [ ]) (
      lib.concatMapStringsSep "\n" (r: "${r} || true") (rules "-D")
    );

    systemd.services.openrouter-route-update = {
      description = "Advertise openrouter.ai's IPs as Tailscale subnet routes";
      # Also at boot: tailscale-autoconnect resets the route list, see tailnet-routes.nix.
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscale-autoconnect.service" "firewall.service" ];
      wants = [ "tailscale-autoconnect.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${routeUpdateScript}/bin/openrouter-route-update";
        ReadWritePaths = [ stateDir ];
      };
    };
    systemd.timers.openrouter-route-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:10:00";
        Persistent = true;
      };
    };
  };
}
