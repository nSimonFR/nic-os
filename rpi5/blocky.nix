{ lib, ... }:
{
  # ── Blocky: network-wide DNS ad/tracker/malware blocker ─────────────
  services.blocky = {
    enable = true;
    settings = {
      # Listen on all interfaces so LAN clients can use the RPi as DNS
      ports = {
        dns = 53;
        http = 4000; # API + Prometheus metrics (localhost only by default)
      };

      # Privacy-respecting upstream DNS (DNS-over-HTTPS)
      upstreams = {
        groups = {
          default = [
            "https://one.one.one.one/dns-query" # Cloudflare
            "https://dns.quad9.net/dns-query" # Quad9 (filters malware)
          ];
        };
        strategy = "parallel_best"; # query all upstreams, use fastest answer
      };

      # Bootstrap DNS — plain IPs to resolve the DoH hostnames above
      bootstrapDns = {
        upstream = "https://one.one.one.one/dns-query";
        ips = [
          "1.1.1.1"
          "1.0.0.1"
        ];
      };

      # ── Blocking ────────────────────────────────────────────────────
      blocking = {
        denylists = {
          # Ads, trackers, analytics, affiliate links
          ads = [
            # Steven Black unified hosts — ads + malware
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
            # Hagezi Pro++ — very strict ads/tracking/analytics/affiliate blocking
            "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/hosts/pro.plus.txt"
          ];
          # Malware, phishing, cryptojacking, scam
          threats = [
            # Hagezi Threat Intelligence Feeds — real-time malware/phishing/scam
            "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/hosts/tif.txt"
          ];
        };

        # Apply all denylist groups to every client on the network
        clientGroupsBlock = {
          default = [
            "ads"
            "threats"
          ];
        };

        # Return 0.0.0.0 / :: for blocked queries (fastest for clients)
        blockType = "zeroIp";

        # Refresh blocklists every 4 hours
        loading = {
          refreshPeriod = "4h";
          downloads = {
            timeout = "60s";
            attempts = 5;
            cooldown = "10s";
          };
        };
      };

      # ── Caching ─────────────────────────────────────────────────────
      caching = {
        minTime = "5m";
        maxTime = "30m";
        maxItemsCount = 0; # unlimited
        prefetching = true;
        prefetchExpires = "2h";
        prefetchThreshold = 5;
      };
    };
  };

  # ── Firewall: allow DNS from the local network ─────────────────────
  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };

  # ── Resolved: free port 53, forward DNS through Blocky ─────────────
  # The stub listener is disabled so Blocky can bind port 53.
  # Queries to 127.0.0.53 (from stub-resolv.conf) still reach Blocky
  # because it listens on 0.0.0.0:53.
  services.resolved.extraConfig = lib.mkAfter ''
    DNSStubListener=no
    DNS=127.0.0.1
  '';
}
