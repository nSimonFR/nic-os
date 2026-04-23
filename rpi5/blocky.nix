{ lib, ... }:
{
  # ── Blocky: network-wide DNS ad/tracker/malware blocker ─────────────
  services.blocky = {
    enable = true;
    settings = {
      # Listen on all interfaces so LAN clients can use the RPi as DNS
      ports = {
        dns = 53;
        http = 4000;
      };

      # Expose /metrics on the HTTP port for Prometheus scraping
      prometheus.enable = true;

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

      # Forward Tailscale MagicDNS names to Tailscale's resolver.
      # Without this, *.ts.net lookups fail because the DoH upstreams
      # don't know about tailnet-internal names (e.g. Aperture).
      conditional = {
        mapping = {
          "gate-mintaka.ts.net" = "100.100.100.100";
        };
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
            # Hagezi Ultimate — most comprehensive ads/tracking/analytics blocking
            "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/hosts/ultimate.txt"
            # OISD Big — aggregated meta-blocklist covering gaps in the above
            "https://big.oisd.nl/domainswild2"
          ];
          # Malware, phishing, cryptojacking, scam
          threats = [
            # Hagezi Threat Intelligence Feeds — real-time malware/phishing/scam
            "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/hosts/tif.txt"
          ];
        };

        allowlists = {
          # Keep Yahoo Finance provider reachable for Ghostfolio.
          # These must be in active clientGroupsBlock groups so they
          # override matching denylist entries.
          ads = [
            ''
              fc.yahoo.com
              finance.yahoo.com
              query1.finance.yahoo.com
              query2.finance.yahoo.com
              guce.yahoo.com
              consent.yahoo.com
              api.datadoghq.com
            ''
          ];
          threats = [
            ''
              fc.yahoo.com
              finance.yahoo.com
              query1.finance.yahoo.com
              query2.finance.yahoo.com
              guce.yahoo.com
              consent.yahoo.com
              api.datadoghq.com
            ''
          ];
        };

        # Apply all denylist groups to every client on the network
        clientGroupsBlock = {
          default = [ "ads" "threats" ];
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
