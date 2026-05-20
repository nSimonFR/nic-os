{ tailnetFqdn, ... }:
# Vaultwarden — self-hosted Bitwarden-compatible password manager.
# Tailscale Serve exposes HTTPS :8222 → the socket-activate proxy on
# 127.0.0.1:8222 → vaultwarden's actual bind at 127.0.0.1:8223.
#
# ADMIN PANEL: https://<tailnetFqdn>:8222/admin
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
      # DOMAIN must include the externalPort since Tailscale Serve exposes
      # :8222, not :443. Required for correct TOTP seed URLs and WebAuthn RP ID.
      DOMAIN = "https://${tailnetFqdn}:${toString externalPort}";

      SIGNUPS_ALLOWED   = false;
      WEBSOCKET_ENABLED = true; # real-time sync across Bitwarden clients

      # SSH key vault + SSH agent feature (desktop ≥ 2024.12.0).
      EXPERIMENTAL_CLIENT_FEATURE_FLAGS = "ssh-key-vault-item,ssh-agent";
    };

    # ADMIN_TOKEN is injected at runtime from agenix.
    # File format: ADMIN_TOKEN=<token>   (one env var per line, no 'export')
    environmentFile = "/run/agenix/vaultwarden-admin-token";
  };

  # ── Socket-activated idle sleep (rpi5/lib/socket-activate.nix) ────────
  # Bitwarden clients are local-first; the first sync after sleep will time
  # out and retry, which is acceptable — the user can still unlock offline.
  services.socketActivate.vaultwarden = {
    enable    = true;
    realUnit  = "vaultwarden.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 600;
  };
}
