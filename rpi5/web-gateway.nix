{ pkgs, ... }:
{
  # Stage 1 web-gateway: central Nginx path-based routing behind Tailscale Serve.
  services.nginx = {
    enable = true;

    appendHttpConfig = ''
      map $http_upgrade $connection_upgrade {
        default upgrade;
        close close;
      }
    '';

    virtualHosts."web-gateway.local" = {
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
