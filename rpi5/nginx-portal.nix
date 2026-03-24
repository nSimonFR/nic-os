{
  ...
}:
# Nginx reverse-proxy portal on port 8080 (loopback only).
# Tailscale Serve owns the Tailscale-interface port for HTTPS/TLS termination;
# nginx sits behind it and only sees plain HTTP from 127.0.0.1.
#
# Routes:
#   /  → Firefly III (8082)
#
# To add a new service:
#   locations."/myservice" = {
#     proxyPass = "http://127.0.0.1:PORT";
#     extraConfig = ''proxy_set_header Host $host; ...'';
#   };
{
  # Restrict Firefly III's nginx vhost to loopback so only the portal can reach it.
  # The nixpkgs firefly-iii module defaults to 0.0.0.0.
  services.nginx.virtualHosts."firefly.local" = {
    listen = [{ addr = "127.0.0.1"; port = 8082; }];
  };

  # Dedicated vhost for nginx_exporter (Prometheus). Only reachable from loopback.
  services.nginx.virtualHosts."nginx-metrics" = {
    listen = [{ addr = "127.0.0.1"; port = 9080; }];
    locations."/nginx_status" = {
      extraConfig = ''
        stub_status on;
        allow 127.0.0.1;
        deny all;
      '';
    };
  };

  # Nginx exporter reads stub_status and exposes Prometheus metrics
  services.prometheus.exporters.nginx = {
    enable        = true;
    port          = 9113;
    listenAddress = "127.0.0.1";
    scrapeUri     = "http://127.0.0.1:9080/nginx_status";
  };

  services.prometheus.scrapeConfigs = [{
    job_name       = "nginx";
    static_configs = [{ targets = [ "127.0.0.1:9113" ]; }];
  }];

  services.nginx.virtualHosts."portal" = {
    listen = [{ addr = "127.0.0.1"; port = 8080; }];

    locations."/" = {
      # Proxy to Firefly III. X-Forwarded-Proto hardcoded to "https" because
      # Tailscale Serve terminates TLS upstream; nginx only sees plain HTTP.
      proxyPass = "http://127.0.0.1:8082";
      extraConfig = ''
        proxy_set_header Host $host:$server_port;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto "https";
        # HSTS: instructs browser to always use HTTPS, preventing cached http:// redirects.
        add_header Strict-Transport-Security "max-age=31536000" always;
      '';
    };
  };
}
