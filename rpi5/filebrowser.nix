{ ... }:
# Filebrowser — lightweight web UI for /mnt/cloud (Storj-backed).
# Served directly via Tailscale Serve on port 8085.
#
# First-run: log in with admin / admin and immediately change the password.
# State (users, settings) is persisted in /var/lib/filebrowser/filebrowser.db.
{
  services.filebrowser = {
    enable = true;
    settings = {
      address = "127.0.0.1";
      port    = 8085;
      root    = "/mnt/cloud";
    };
  };
}
