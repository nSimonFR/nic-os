{ config, lib, pkgs, ... }:
let
  prometheusPort = 9090;
in
{
  # ── Prometheus ──────────────────────────────────────────────────────────────
  services.prometheus = {
    enable         = true;
    port           = prometheusPort;
    listenAddress  = "127.0.0.1";
    retentionTime  = "30d";
    # Disable build-time config validation: bearer_token_file for Home Assistant
    # points to a runtime secret that doesn't exist in the Nix build sandbox.
    checkConfig    = false;

    globalConfig = {
      scrape_interval     = "15s";
      evaluation_interval = "15s";
    };

    scrapeConfigs = [
      { job_name       = "prometheus";
        static_configs = [{ targets = [ "127.0.0.1:${toString prometheusPort}" ]; }]; }
      { job_name       = "node";
        static_configs = [{ targets = [ "127.0.0.1:9100" ]; }]; }
      { job_name       = "cadvisor";
        static_configs = [{ targets = [ "127.0.0.1:9338" ]; }]; }
      # Blackbox HTTP probe for openclaw (no dedicated service .nix)
      { job_name       = "blackbox-openclaw";
        metrics_path   = "/probe";
        params         = { module = [ "http_2xx" ]; };
        static_configs = [{ targets = [ "http://127.0.0.1:18789/health" ]; }];
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
        ]; }
    ];
  };

  # ── Exporters ───────────────────────────────────────────────────────────────
  services.prometheus.exporters = {
    # System: CPU, memory, disk, network, filesystem, systemd units
    node = {
      enable            = true;
      port              = 9100;
      listenAddress     = "127.0.0.1";
      enabledCollectors = [ "systemd" "textfile" ];
      extraFlags        = [ "--collector.textfile.directory=/var/lib/node-exporter-textfile" ];
    };

    # Blackbox: HTTP probes for services without native Prometheus endpoints
    blackbox = {
      enable        = true;
      port          = 9115;
      listenAddress = "127.0.0.1";
      configFile    = pkgs.writeText "blackbox.yml" ''
        modules:
          http_2xx:
            prober: http
            timeout: 10s
            http:
              valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
              valid_status_codes: []
              follow_redirects: true
              preferred_ip_protocol: "ip4"
      '';
    };
  };

  # Memory limit: 30d TSDB retention can grow; throttle before hard-killing
  # (currently ~129 MiB RSS but grows over time).
  systemd.services.prometheus.serviceConfig = {
    MemoryHigh = "320M";
    MemoryMax  = "512M";
  };

  # ── cAdvisor (Docker container metrics) ─────────────────────────────────────
  # Port 8080 (default) conflicts with nginx; use 9338 instead.
  services.cadvisor = {
    enable        = true;
    port          = 9338;
    listenAddress = "127.0.0.1";
  };

  # cAdvisor sits at ~100 MiB; cap it so it can't grow unbounded.
  systemd.services.cadvisor.serviceConfig = {
    MemoryHigh = "128M";
    MemoryMax  = "192M";
  };
}
