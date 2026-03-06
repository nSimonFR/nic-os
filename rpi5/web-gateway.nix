{ lib, ... }:
let
  # Add services here to expose them as /<name>/ via the gateway.
  routes = [
    { name = "firefly"; localPort = 8080; websocket = false; }
    { name = "ghostfolio"; localPort = 3333; websocket = true; }
    { name = "openclaw"; localPort = 18789; websocket = true; }
  ];

  mkExtraConfig = route: ''
    ${lib.optionalString route.websocket ''
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
    ''}
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Prefix /${route.name};
  '';

  mkRouteLocations = route: [
    {
      name = "= /${route.name}";
      value = { return = "302 /${route.name}/"; };
    }
    {
      name = "/${route.name}/";
      value = {
        proxyPass = "http://127.0.0.1:${toString route.localPort}/";
        extraConfig = mkExtraConfig route;
      };
    }
  ];

  routeLocations = builtins.listToAttrs (builtins.concatMap mkRouteLocations routes);
in
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
      locations = {
        "/" = {
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
      } // routeLocations;
    };
  };
}
