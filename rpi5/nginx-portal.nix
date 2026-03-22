{
  lib,
  ...
}:
# Nginx reverse-proxy portal on port 8080 (loopback only).
# Tailscale Serve owns the Tailscale-interface port for HTTPS/TLS termination;
# nginx sits behind it and only sees plain HTTP from 127.0.0.1.
#
# Routes:
#   /openclaw  → openclaw gateway (18789) — also handles WebSocket upgrades
#   /          → Firefly III (8082)
#
# To add a new service:
#   locations."/myservice" = {
#     proxyPass = "http://127.0.0.1:PORT";
#     extraConfig = ''proxy_set_header Host $host; ...'';
#   };
{
  services.nginx.virtualHosts."portal" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = 8080;
      }
    ];

    locations."/openclaw" = {
      # No trailing slash: full URI (including /openclaw prefix) is forwarded so the
      # gateway can match its basePath = "/openclaw" for control-ui routing.
      proxyPass = "http://127.0.0.1:18789";
      extraConfig = ''
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };

    locations."/" = {
      # Catch-all: proxy to Firefly III.
      # X-Forwarded-Proto hardcoded to "https" because Tailscale Serve terminates TLS
      # upstream — nginx only ever receives plain HTTP from the Tailscale Serve proxy.
      proxyPass = "http://127.0.0.1:8082";
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto "https";
        # HSTS: instructs browser to always use HTTPS, preventing cached http:// redirects.
        add_header Strict-Transport-Security "max-age=31536000" always;
      '';
    };
  };
}
