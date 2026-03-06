{ pkgs, ... }:
{
  # Stage 1 web-gateway: central Nginx path-based routing behind Tailscale Serve.
  #
  # Goals for this slice:
  # - Keep existing direct service endpoints operational (e.g. tailscale :3333).
  # - Add a single HTTPS entrypoint on localhost:8443 for incremental migration.
  # - Provide path routes for Firefly, Ghostfolio, and OpenClaw.
  #
  # Planned next slices:
  # 1) Move more services behind this gateway with explicit path prefixes.
  # 2) Decide whether to retire legacy direct Tailscale Serve ports.
  # 3) Tighten auth/TLS policies and optional access controls per route.

  services.nginx = {
    enable = true;

    # Include websocket-compatible defaults for OpenClaw gateway traffic.
    appendHttpConfig = ''
      map $http_upgrade $connection_upgrade {
        default upgrade;
        close close;
      }
    '';

    virtualHosts."web-gateway.local" = {
      # Local-only listener used by Tailscale Serve as HTTPS frontend.
      listen = [
        {
          addr = "127.0.0.1";
          port = 8443;
        }
      ];

      # Backward compatibility: keep https://rpi5:443 behaving like OpenClaw.
      locations."/" = {
        proxyPass = "http://127.0.0.1:18789/";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };

      # New staged path routes.
      locations."= /firefly" = {
        return = "302 /firefly/";
      };
      locations."/firefly/" = {
        proxyPass = "http://127.0.0.1:8080/";
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Prefix /firefly;
        '';
      };

      locations."= /ghostfolio" = {
        return = "302 /ghostfolio/";
      };
      locations."/ghostfolio/" = {
        proxyPass = "http://127.0.0.1:3333/";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Prefix /ghostfolio;
        '';
      };

      locations."= /openclaw" = {
        return = "302 /openclaw/";
      };
      locations."/openclaw/" = {
        proxyPass = "http://127.0.0.1:18789/";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Prefix /openclaw;
        '';
      };
    };
  };
}
