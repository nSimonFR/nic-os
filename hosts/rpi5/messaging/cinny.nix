# Cinny (web client) and the homeserver behind one loopback vhost, published by
# Tailscale Serve (nic.services.matrix.public in tuwunel.nix). Static files: no
# process of its own. Element X / FluffyChat log in against the same URL.
{ config, pkgs, ... }:
let
  inherit (config.nic.messaging) homeserverPort cinnyPort;
  publicUrl = config.nic.services.matrix.public.publicUrl;
  cinny = pkgs.cinny.override {
    conf = {
      defaultHomeserver = 0;
      homeserverList = [ publicUrl ];
      allowCustomHomeservers = false;
    };
  };
  homeserver = {
    proxyPass = "http://127.0.0.1:${toString homeserverPort}";
    extraConfig = ''
      client_max_body_size 50m;
      proxy_read_timeout 600s;
    '';
  };
in
{
  services.nginx.virtualHosts.matrix = {
    listen = [
      {
        addr = "127.0.0.1";
        port = cinnyPort;
        ssl = false;
      }
    ];
    root = cinny;
    locations = {
      "/_matrix/" = homeserver;
      "/.well-known/matrix/" = homeserver;
      # Client-side routing: every unknown path is the app.
      "/".tryFiles = "$uri $uri/ /index.html";
    };
  };
}
