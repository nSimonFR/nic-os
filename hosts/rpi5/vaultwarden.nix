{ pkgs, tailnetFqdn, username, ... }:
# Vaultwarden — self-hosted Bitwarden-compatible password manager.
# Public at https://<tailnetFqdn>/vaultwarden via the 443 path-mux (front-proxy.nix)
# → the socket-activate proxy on 127.0.0.1:8222 → vaultwarden on 127.0.0.1:8223.
# Public so Emergency Access grantees need no tailnet.
#
# ADMIN PANEL: https://<tailnetFqdn>/vaultwarden/admin — tailnet only, 404 over funnel.
# Admin token is managed via agenix (vaultwarden-admin-token secret).
#
# FIRST-TIME SETUP:
#   1. Deploy with SIGNUPS_ALLOWED = false (default).
#   2. Open the admin panel, invite yourself via "Users → Invite User".
#      Activation link: journalctl -u vaultwarden -b | grep -i invite
#   3. Complete signup via the web vault.
#
# SSH AGENT (requires Bitwarden desktop ≥ 2024.12.0):
#   - Enable in desktop Settings → SSH Agent.
#   - SSH keys with passphrases are NOT supported by the agent.
#   - Keys imported from 1Password .1pux become empty secure notes (bitwarden/clients#13977);
#     re-add them manually as SSH Key vault items after import.
let
  externalPort = 8222;
  backendPort  = 8223;
in {
  services.vaultwarden = {
    enable    = true;
    dbBackend = "sqlite";
    backupDir = "/var/backup/vaultwarden"; # built-in daily sqlite3 hot backup at 23:00

    config = {
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT    = backendPort;
      # The path is how vaultwarden learns its mux prefix; it serves under it.
      DOMAIN = "https://${tailnetFqdn}/vaultwarden";

      # Accounts only via the admin panel's invite (tailnet-only).
      SIGNUPS_ALLOWED        = false;
      INVITATIONS_ALLOWED    = false;
      PASSWORD_HINTS_ALLOWED = false;
      # Set by front-proxy.nix from tailscaled's X-Forwarded-For, which it rewrites
      # to the real client; a client-sent X-Real-IP passes through it untouched.
      IP_HEADER = "X-Client-IP";
      WEBSOCKET_ENABLED = true; # real-time sync across Bitwarden clients

      # SSH key vault + SSH agent feature (desktop ≥ 2024.12.0).
      EXPERIMENTAL_CLIENT_FEATURE_FLAGS = "ssh-key-vault-item,ssh-agent";

      # Mail via hydroxide (hosts/rpi5/hydroxide.nix): plaintext on loopback, and
      # Proton only accepts the account address as From. Emergency Access needs it
      # to tell the grantor a request was made.
      SMTP_HOST          = "127.0.0.1";
      SMTP_PORT          = 1025;
      SMTP_SECURITY      = "off";
      SMTP_USERNAME      = "${username}@protonmail.com";
      SMTP_FROM          = "${username}@protonmail.com";
      SMTP_FROM_NAME     = "Vaultwarden";
      SMTP_PASSWORD_FILE = "/run/credentials/vaultwarden.service/smtp-password";

      # Defaults run hourly at :03/:07, but the service sleeps after 10 idle min,
      # so they'd almost never fire. Every 5 min lands inside each wake below.
      EMERGENCY_NOTIFICATION_REMINDER_SCHEDULE = "0 */5 * * * *";
      EMERGENCY_REQUEST_TIMEOUT_SCHEDULE       = "0 */5 * * * *";
    };

    # ADMIN_TOKEN is injected at runtime from agenix.
    # File format: ADMIN_TOKEN=<token>   (one env var per line, no 'export')
    environmentFile = "/run/agenix/vaultwarden-admin-token";
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────
  # Bitwarden clients are local-first; the first sync after sleep will time
  # out and retry, which is acceptable — the user can still unlock offline.
  #
  # readyProbe is required: vaultwarden is Type=simple and Rocket takes
  # ~1s after fork to bind, which is enough for systemd-socket-proxyd to
  # race the listen() and return ECONNREFUSED to the client.
  services.socketActivate.vaultwarden = {
    enable    = true;
    realUnit  = "vaultwarden.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/vaultwarden/alive";
      expectStatus = 200;
      timeoutSec   = 30;
    };
  };

  # LoadCredential, not the hydroxide group: the module sets PrivateUsers, which
  # maps every supplementary group to nobody.
  systemd.services.vaultwarden.serviceConfig.LoadCredential =
    [ "smtp-password:/run/agenix/protonmail-bridge-password" ];

  # Wake it hourly so an Emergency Access wait period elapses and gets granted
  # even when nobody opens the vault.
  systemd.services.vaultwarden-wake = {
    description = "Wake Vaultwarden for its scheduled jobs";
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      ExecStart = "${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 60 http://127.0.0.1:${toString externalPort}/vaultwarden/alive";
    };
  };
  systemd.timers.vaultwarden-wake = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "5m";
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.vaultwarden = {
    backup        = [ "unit" ];
    backupUnits   = [ "vaultwarden-backup.service" ];   # backups.nix
    heavyUnits    = [ "vaultwarden.service" ];
    heavyPriority = 150;

    public = {
      order   = 160;
      port    = 443;
      backend = "http://127.0.0.1:${toString externalPort}";
      proxied = true;
      muxPath = "/vaultwarden";
      authenticated = true;
      tile = {
        name        = "Vaultwarden";
        icon        = "vaultwarden.svg";
        category    = "Apps";
        description = "Password manager";
        # No native homepage widget exists, so this reads Vaultwarden's SQLite
        # directly — the daily poll never wakes the socket-activated service and
        # needs no API key.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/vaultwarden";
          refreshInterval = 3600000;
          mappings = [
            # `Users` was 2 and a two-person vault does not gain users. On a
            # password manager the figure that moves — and that says whether
            # anything is being rotated — is how many items changed this month.
            { field = "items";       label = "Items";    format = "number"; }
            { field = "changed_30d"; label = "Changed";  format = "number"; }
            { field = "devices";     label = "Devices";  format = "number"; }
          ];
        };
      };
    };
  };
}
