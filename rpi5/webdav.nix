{ username, ... }:
# WebDAV server for /mnt/cloud — enables native Files app mounting on iOS/macOS.
# Binds on all interfaces; firewall restricts to Tailscale CGNAT range only.
# iOS Files app connects via plain HTTP to the Tailscale IP (traffic is
# encrypted by the Tailscale tunnel, so HTTP here is fine).
# Connection: http://rpi5.gate-mintaka.ts.net:8087
{
  services.webdav = {
    enable = true;
    user   = username;
    settings = {
      address     = "0.0.0.0";
      port        = 8087;
      auth        = false;
      directory   = "/mnt/cloud";
      permissions = "CRUD";
    };
  };

  # Allow WebDAV only from Tailscale CGNAT range (100.64.0.0/10).
  networking.firewall.extraInputRules = ''
    ip saddr 100.64.0.0/10 tcp dport 8087 accept
    tcp dport 8087 drop
  '';
}
