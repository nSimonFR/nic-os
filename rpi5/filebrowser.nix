{ username, ... }:
# Filebrowser — lightweight web UI for /mnt/cloud (Storj-backed).
# Served directly via Tailscale Serve on port 8085.
#
# Runs as the primary user so it shares ownership with the storj loop mount.
# State (users, settings) persisted in /var/lib/filebrowser/database.db.
{
  services.filebrowser = {
    enable = true;
    user   = username;
    settings = {
      address = "127.0.0.1";
      port    = 8085;
      root    = "/mnt/cloud";
    };
  };
}
