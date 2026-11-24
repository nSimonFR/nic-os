# hosts/rpi5/security/pocket-id.nix
#
# Pocket ID: passkey-only OIDC provider for Nico and Alfie, funneled on
# :8443 so it works off the tailnet like the apps it logs into. No
# signups; users are invited from the admin UI. Never put Vaultwarden, SSH or Tailscale behind it:
# they are the way back in.
#
# Switching a service to SSO, in that service's module:
#
#   nic.sso.clients.immich = {
#     name = "Immich";
#     callbackUrls = [ "${origin}/auth/login" "app.immich:///oauth-callback" ];
#     secretGroup = "immich";
#   };
#
# then point the app at `config.nic.sso.issuer`, client id `immich` and the
# secret in `config.nic.sso.clients.immich.secretFile` (or set `envVar` and
# load `envFile` when the app only reads it from the environment), and order
# its unit after `pocket-id-clients.service`. Keep the
# app's local login as the fallback.
#
# Lost passkey: an admin creates a login code for the user in the admin UI; for
# the last admin, run `pocket-id one-time-access-token <user>` as the pocket-id
# user in /var/lib/pocket-id with the unit's environment.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  inherit (lib) mkOption types;
  port = 1411;
  secretsDir = "/var/lib/pocket-id-clients";
  issuer = config.nic.services.pocket-id.public.publicUrl;

  clientsFile = pkgs.writeText "pocket-id-clients.json" (
    builtins.toJSON (
      lib.mapAttrsToList (id: c: {
        inherit id;
        inherit (c)
          name
          secretFile
          secretGroup
          envVar
          envFile
          ;
        idFile = "${secretsDir}/registered/${id}";
        callbackURLs = c.callbackUrls;
        logoutCallbackURLs = c.logoutCallbackUrls;
        launchURL = c.launchUrl;
        inherit (c) allowedGroups;
        isPublic = c.public;
        pkceEnabled = c.pkce;
      }) config.nic.sso.clients
    )
  );

  clientModule = types.submodule (
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Display name on the Pocket ID dashboard.";
        };
        callbackUrls = mkOption {
          type = types.nonEmptyListOf types.str;
          description = "Allowed redirect URIs (`*` wildcards allowed).";
        };
        logoutCallbackUrls = mkOption {
          type = types.listOf types.str;
          default = [ ];
        };
        launchUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Where the dashboard tile links.";
        };
        allowedGroups = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = [ "admins" ];
          example = [ "famille" ];
          description = ''
            Pocket ID group names allowed to use this client; the client is
            marked group-restricted, so nobody else can sign in to it. null
            leaves the restriction as set in Pocket ID; an unrestricted client
            is open to every user, and Pocket ID drops its (unused) groups on
            any update.
          '';
        };
        pkce = mkOption {
          type = types.bool;
          default = false;
          description = "Require PKCE. Only for apps that send it.";
        };
        public = mkOption {
          type = types.bool;
          default = false;
          description = "Public client (no secret), e.g. a native app.";
        };
        secretGroup = mkOption {
          type = types.str;
          description = "Group that may read `secretFile` (the app's service group).";
        };
        secretFile = mkOption {
          type = types.str;
          readOnly = true;
          default = "${secretsDir}/secrets/${name}";
          description = "Client secret, root:secretGroup 0440, written by pocket-id-clients.";
        };
        envVar = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "OAUTH_CLIENT_SECRET";
          description = ''
            For apps that only read the secret from the environment: also write
            `<envVar>=<secret>` to `envFile`, for the unit's EnvironmentFile
            (read by systemd as root, so it works with DynamicUser too).
          '';
        };
        envFile = mkOption {
          type = types.str;
          readOnly = true;
          default = "${secretsDir}/env/${name}";
          description = "Env file written when `envVar` is set (root:secretGroup 0440).";
        };
      };
    }
  );
in
{
  options.nic.sso = {
    issuer = mkOption {
      type = types.str;
      readOnly = true;
      default = issuer;
      description = "OIDC issuer URL (discovery at /.well-known/openid-configuration).";
    };
    clients = mkOption {
      type = types.attrsOf clientModule;
      default = { };
      description = "OIDC clients synced into Pocket ID; the attr name is the client id.";
    };
  };

  config = {
    age.secrets.pocket-id-env = {
      # ENCRYPTION_KEY (changing it orphans the DB) and STATIC_API_KEY (admin API).
      file = ../secrets/pocket-id-env.age;
      owner = "pocket-id";
    };

    services.pocket-id = {
      enable = true;
      environmentFile = config.age.secrets.pocket-id-env.path;
      settings = {
        APP_URL = issuer;
        HOST = "127.0.0.1";
        PORT = toString port;
        TRUST_PROXY = true; # tailscale serve; bound to loopback only
        ANALYTICS_DISABLED = true;

        # App settings come from here, not the admin UI (which goes read-only).
        UI_CONFIG_DISABLED = true;
        APP_NAME = "nic-os";
        # Emails are set by the admin only, so vouch for them: apps that link an
        # existing account by email (Karakeep, Dawarich, Sure…) require
        # email_verified. Users editing their own email would break that.
        EMAILS_VERIFIED = true;
        ALLOW_OWN_ACCOUNT_EDIT = false;
        # Mail via hydroxide (hosts/rpi5/knowledge/hydroxide.nix): plaintext on
        # loopback; Proton only accepts the account address as From.
        SMTP_HOST = "127.0.0.1";
        SMTP_PORT = "1025";
        SMTP_TLS = "none";
        SMTP_USER = "${username}@protonmail.com";
        SMTP_FROM = "${username}@protonmail.com";
        SMTP_PASSWORD_FILE = "/run/credentials/pocket-id.service/smtp-password";
        # Mail on a sign-in from a browser it doesn't know.
        EMAIL_LOGIN_NOTIFICATION_MODE = "browserRecognition";
        # An admin can mail a login code (onboarding, lost passkey). Users can't
        # request one themselves: that would make the mailbox a login factor.
        EMAIL_ONE_TIME_ACCESS_AS_ADMIN_ENABLED = true;
      };
    };

    # LoadCredential, not the hydroxide group: the agenix file stays 0440
    # hydroxide, and systemd hands this unit a private copy.
    systemd.services.pocket-id.serviceConfig.LoadCredential = [
      "smtp-password:/run/agenix/protonmail-bridge-password"
    ];

    # Funneled, an empty database would publish /setup (first visitor becomes
    # admin). Refuse to start without a user; for a fresh install, set funnel
    # to false, register the admin from the tailnet, then flip it back.
    systemd.services.pocket-id.serviceConfig.ExecStartPre =
      lib.mkIf config.nic.services.pocket-id.public.funnel (
        pkgs.writeShellScript "pocket-id-require-admin" ''
          db=/var/lib/pocket-id/data/pocket-id.db
          n=$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" 'SELECT count(*) FROM users' 2>/dev/null || true)
          if [ "''${n:-0}" -gt 0 ] 2>/dev/null; then exit 0; fi
          echo "pocket-id: no user in $db while funneled; /setup would be public. Refusing to start." >&2
          exit 1
        ''
      );

    systemd.services.pocket-id-clients = {
      description = "Sync nic.sso.clients into Pocket ID";
      after = [ "pocket-id.service" ];
      requires = [ "pocket-id.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        POCKET_ID_URL = "http://127.0.0.1:${toString port}";
        CLIENTS_FILE = clientsFile;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Apps order after this unit; a hung Pocket ID must not hold them back
        # (oneshot has no start timeout by default).
        TimeoutStartSec = "5min";
        EnvironmentFile = config.age.secrets.pocket-id-env.path;
        StateDirectory = "pocket-id-clients";
        StateDirectoryMode = "0755";
        ExecStart = "${pkgs.nicos-scripts}/bin/pocket-id-clients";
      };
    };

    nic.services.pocket-id = {
      backup = [ "unit" ];
      backupUnits = [ "pocket-id-backup.service" ]; # backups.nix
      appUnits = [ "pocket-id.service" ];
      public = {
        order = 910;
        port = 8443;
        backend = "http://127.0.0.1:${toString port}";
        # Public so SSO works off the tailnet, like the apps behind it. The
        # ExecStartPre above keeps it down while no admin exists.
        funnel = true;
        authenticated = true;
      };
    };
  };
}
