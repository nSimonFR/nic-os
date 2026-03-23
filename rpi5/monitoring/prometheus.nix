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
      { job_name = "prometheus";
        static_configs = [{ targets = [ "127.0.0.1:${toString prometheusPort}" ]; }]; }
      { job_name = "node";
        static_configs = [{ targets = [ "127.0.0.1:9100" ]; }]; }
      { job_name = "nginx";
        static_configs = [{ targets = [ "127.0.0.1:9113" ]; }]; }
      { job_name = "postgres";
        static_configs = [{ targets = [ "127.0.0.1:9187" ]; }]; }
      { job_name = "redis";
        static_configs = [{ targets = [ "127.0.0.1:9121" ]; }]; }
      { job_name = "blocky";
        static_configs = [{ targets = [ "127.0.0.1:4000" ]; }]; }
      { job_name = "grafana";
        static_configs = [{ targets = [ "127.0.0.1:3000" ]; }]; }
      # Home Assistant entity states — requires Long-Lived Access Token.
      # echo TOKEN | sudo tee /etc/home-assistant/ha-api-token && sudo chmod 640 /etc/home-assistant/ha-api-token
      { job_name          = "home_assistant";
        static_configs    = [{ targets = [ "127.0.0.1:8123" ]; }];
        metrics_path      = "/api/prometheus";
        bearer_token_file = "/etc/home-assistant/ha-api-token"; }
      { job_name = "cadvisor";
        static_configs = [{ targets = [ "127.0.0.1:9338" ]; }]; }
      # Blackbox HTTP probes: up/down for services without native exporters
      { job_name     = "blackbox";
        metrics_path = "/probe";
        params       = { module = [ "http_2xx" ]; };
        static_configs = [{
          targets = [
            "http://127.0.0.1:8082"           # firefly-iii
            "http://127.0.0.1:13333"          # ghostfolio
            "http://127.0.0.1:8123"           # home-assistant
            "http://127.0.0.1:18789/health"   # openclaw
            "http://127.0.0.1:8081"           # truelayer2firefly
          ];
        }];
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

    # Nginx via stub_status (see nginx-portal.nix for the stub_status vhost on 9080)
    nginx = {
      enable        = true;
      port          = 9113;
      listenAddress = "127.0.0.1";
      scrapeUri     = "http://127.0.0.1:9080/nginx_status";
    };

    # PostgreSQL — peer auth as postgres superuser; no extra role needed
    postgres = {
      enable              = true;
      port                = 9187;
      listenAddress       = "127.0.0.1";
      runAsLocalSuperUser = true;
    };

    # Redis (Ghostfolio instance on 6379)
    redis = {
      enable        = true;
      port          = 9121;
      listenAddress = "127.0.0.1";
      extraFlags    = [ "--redis.addr redis://127.0.0.1:6379" ];
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

  # ── cAdvisor (Docker container metrics) ─────────────────────────────────────
  # Port 8080 (default) conflicts with nginx; use 9338 instead.
  services.cadvisor = {
    enable        = true;
    port          = 9338;
    listenAddress = "127.0.0.1";
  };

  # ── Textfile collector directory ─────────────────────────────────────────────
  # World-readable so node_exporter (DynamicUser) can read .prom files.
  # Also creates the HA bearer token placeholder (populated manually after deploy).
  systemd.tmpfiles.rules = [
    "f /etc/home-assistant/ha-api-token 0640 root prometheus - -"
  ];
}
