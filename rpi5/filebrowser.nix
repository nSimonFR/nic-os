{ username, ... }:
# Filebrowser — lightweight web UI for /mnt/cloud (Storj-backed).
# Served directly via Tailscale Serve on port 8085.
#
# Runs as the primary user so it shares ownership with the storj loop mount.
# State (users, settings) persisted in /var/lib/filebrowser/database.db.
#
# First run: filebrowser generates a random password for the 'admin' user and
# prints it once to stdout. Retrieve it with:
#   journalctl -u filebrowser -b | grep password
{
  services.filebrowser = {
    enable = true;
    user   = username;
    group  = "users";
    settings = {
      address = "127.0.0.1";
      port    = 8085;
      root    = "/mnt/cloud";
    };
  };
}
