# hosts/rpi5/security/pocket-id.nix
#
# Pocket ID: passkey-only OIDC provider for Nico and Alfie, on :8443 (a funnel
# port, so it can later work off the tailnet like the apps it logs into). No
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
# secret in `config.nic.sso.clients.immich.secretFile`, and order its unit
# after `pocket-id-clients.service`. Keep the app's local login as the fallback.
#
# Lost passkey: an admin creates a login code for the user in the admin UI; for
# the last admin, run `pocket-id one-time-access-token <user>` as the pocket-id
# user in /var/lib/pocket-id with the unit's environment.
{
  config,
  lib,
  pkgs,
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
        inherit (c) name secretFile secretGroup;
        idFile = "${secretsDir}/registered/${id}";
        callbackURLs = c.callbackUrls;
        logoutCallbackURLs = c.logoutCallbackUrls;
        launchURL = c.launchUrl;
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
      };
    };

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
        # Tailnet-only until the first admin exists: /setup is open to anyone
        # before that. Flipping it keeps the origin, so passkeys stay valid.
        funnel = false;
        authenticated = true;
      };
    };
  };
}
