# hosts/rpi5/security/shellwatch.nix
#
# ShellWatch: SSH-agent signatures approved with a passkey on the phone (Web
# Push → Face ID). Three pieces on this host:
#
#   shellwatch-hydra   Ory Hydra, the OAuth authority (127.0.0.1:14444/14445)
#   shellwatch         the server + UI (127.0.0.1:13990, served on :3995)
#   shellwatch-agent   nsimon's user unit: an SSH-agent socket whose only key is
#                      the passkey; each sign request is a push to the phone
#
# sudo: `phone-sudo cmd` points SSH_AUTH_SOCK at that socket, and
# pam_ssh_agent_webauthn verifies the signature against the root-owned key
# below, UV (Face ID or device code) required. Plain `sudo` never asks the
# phone, so the TOTP path can't wait on a push. Stack order: rssh (mac-sudo),
# this, then TOTP (sudo-totp.nix).
#
# The relay can only deny or delay: the Pi checks the signature itself.
# The approval screen shows no command.
#
# One-time agent login (needs a browser that can reach the Pi's loopback):
#   ssh -L <port>:127.0.0.1:<port> rpi5, then open the URL that
#   `shellwatch-agent login --server <origin>` prints.
{
  config,
  lib,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  port = 13990;
  hydraPublicPort = 14444;
  hydraAdminPort = 14445;
  stateDir = "/var/lib/shellwatch";
  origin = config.nic.services.shellwatch.public.publicUrl;

  shellwatch = pkgs.callPackage ../../../pkgs/services/shellwatch.nix { };
  shellwatch-agent = pkgs.callPackage ../../../pkgs/services/shellwatch-agent.nix { };
  pamWebauthn = pkgs.callPackage ../../../pkgs/services/pam-ssh-agent-webauthn.nix { };

  # The iPhone passkey (rpId = tailnetFqdn), under the webauthn-sk type name
  # pam_ssh_agent_webauthn reads (the agent advertises it as sk-ecdsa-…).
  passkeyWebauthn = "webauthn-sk-ecdsa-sha2-nistp256@openssh.com AAAAK3dlYmF1dGhuLXNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBEm05RhQsrnP53UUhsQ0Z69blDBeQsGFCkwD3w1UO52/7nLiW4gkKEpzYOCaizQH/lVpjfHVPyeWxHz3dnB4EJMAAAAYcnBpNS5nYXRlLW1pbnRha2EudHMubmV0";

  hydraConfig = pkgs.writeText "shellwatch-hydra.json" (
    builtins.toJSON {
      serve = {
        cookies.same_site_mode = "Lax";
        public = {
          host = "127.0.0.1";
          port = hydraPublicPort;
          cors = {
            enabled = true;
            allowed_origins = [ origin ];
          };
        };
        admin = {
          host = "127.0.0.1";
          port = hydraAdminPort;
        };
      };
      urls = {
        self = {
          issuer = origin;
          public = origin;
        };
        login = "${origin}/api/hydra/login";
        consent = "${origin}/api/hydra/consent";
        logout = "${origin}/api/hydra/logout";
        error = "${origin}/api/hydra/error";
        post_logout_redirect = "${origin}/";
      };
      oidc = {
        subject_identifiers.supported_types = [ "public" ];
        # ShellWatch mediates registration (/api/hydra/register, CIMD).
        dynamic_client_registration.enabled = false;
      };
      strategies.access_token = "opaque";
      ttl = {
        access_token = "30m";
        refresh_token = "720h";
        id_token = "30m";
        auth_code = "10m";
      };
      oauth2.pkce.enforced = false; # every client is public and uses PKCE anyway
      log = {
        level = "info";
        format = "text";
      };
    }
  );

  # JSON is YAML. vapid.privateKey is spliced in at start (no env override).
  shellwatchConfig = pkgs.writeText "shellwatch-config.json" (
    builtins.toJSON {
      server = {
        inherit port;
        externalUrl = origin;
        trustProxy = "127.0.0.1"; # tailscale serve
      };
      keyDirectory = "${stateDir}/keys";
      security = {
        rpId = tailnetFqdn;
        trustedWebauthnOrigins = [ origin ];
        # /mcp and /agent-proxy: loopback and the tailnet only.
        allowedNetworks = [
          "127.0.0.1/32"
          "::1/128"
          "100.64.0.0/10"
          "fd7a:115c:a1e0::/48"
        ];
      };
      vapid = {
        subject = origin;
        publicKey = "BC5uz_xEdz-sxt41JGTThQTV5Dn6U-4MWtNdeWJ5MH4KDU0pC1FB1OaUz82NzRmKVr7OeetthW46WxIKQE7uH38";
      };
      agentSocket.proxyEnabled = true;
      hydra = {
        publicUrl = origin;
        adminUrl = "http://127.0.0.1:${toString hydraAdminPort}";
        # Upstream calls this dev-only; it is what keeps one origin without a
        # path-routing proxy (tailscale serve maps a whole port).
        devProxyUpstream = "http://127.0.0.1:${toString hydraPublicPort}";
        spa.clientId = "shellwatch-web";
      };
    }
  );

  hardening = {
    User = "shellwatch";
    Group = "shellwatch";
    StateDirectory = "shellwatch";
    StateDirectoryMode = "0700";
    WorkingDirectory = stateDir;
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    Restart = "on-failure";
    RestartSec = 5;
  };
in
{
  users.users.shellwatch = {
    isSystemUser = true;
    group = "shellwatch";
  };
  users.groups.shellwatch = { };

  age.secrets = {
    # SECRETS_SYSTEM=… — encrypts Hydra's DB; changing it orphans every client.
    shellwatch-hydra-env.file = ../secrets/shellwatch-hydra-env.age;
    # Bare base64url key; changing it voids the phone's push subscription.
    shellwatch-vapid-private-key.file = ../secrets/shellwatch-vapid-private-key.age;
  };

  systemd.services.shellwatch-hydra = {
    description = "Ory Hydra for ShellWatch";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    environment.DSN = "sqlite://${stateDir}/hydra.sqlite?_fk=true";
    serviceConfig = hardening // {
      EnvironmentFile = config.age.secrets.shellwatch-hydra-env.path;
      ExecStartPre = "${lib.getExe pkgs.ory-hydra} migrate sql -e --yes";
      ExecStart = "${lib.getExe pkgs.ory-hydra} serve all --config ${hydraConfig}";
    };
  };

  systemd.services.shellwatch = {
    description = "ShellWatch passkey approval server";
    after = [ "shellwatch-hydra.service" ];
    requires = [ "shellwatch-hydra.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HOST = "127.0.0.1";
      SHELLWATCH_CONFIG = "/run/shellwatch/config.yaml";
      SHELLWATCH_DB = "sqlite:${stateDir}/shellwatch.db";
    };
    serviceConfig = hardening // {
      RuntimeDirectory = "shellwatch";
      RuntimeDirectoryMode = "0700";
      LoadCredential = "vapid:${config.age.secrets.shellwatch-vapid-private-key.path}";
      ExecStartPre = pkgs.writeShellScript "shellwatch-config" ''
        set -eu
        umask 077
        mkdir -p ${stateDir}/keys
        ${lib.getExe pkgs.jq} --rawfile k "$CREDENTIALS_DIRECTORY/vapid" \
          '.vapid.privateKey = ($k | rtrimstr("\n"))' ${shellwatchConfig} \
          > /run/shellwatch/config.yaml
      '';
      ExecStart = lib.getExe shellwatch;
    };
  };

  # The agent keeps its refresh token in ~/.config/shellwatch/credentials. It
  # tries the Secret Service first, and "name is not activatable" (no keyring
  # on this host) is not on its fall-back list; a dead bus address is.
  systemd.user.services.shellwatch-agent = {
    description = "ShellWatch SSH agent (passkey on the phone)";
    unitConfig.ConditionUser = "nsimon";
    wantedBy = [ "default.target" ];
    environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=/nonexistent";
    serviceConfig = {
      ExecStart = "${lib.getExe shellwatch-agent} --server ${origin}";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # ── sudo ────────────────────────────────────────────────────────────────
  security.pam.services.sudo.rules.auth.shellwatch = {
    order = config.security.pam.services.sudo.rules.auth.rssh.order + 10;
    control = "sufficient";
    modulePath = "${pamWebauthn}/lib/security/pam_ssh_agent_webauthn.so";
    args = [
      "file=/etc/ssh/sudo_passkeys"
      "verify_required=yes"
    ];
  };
  assertions = [
    (
      let
        inherit (config.security.pam.services.sudo.rules.auth) rssh shellwatch totp;
      in
      {
        assertion = rssh.order < shellwatch.order && shellwatch.order < totp.order;
        message = "sudo PAM order must be rssh (mac-sudo), shellwatch (phone-sudo), totp";
      }
    )
  ];

  # A copy, not a store symlink: the module refuses symlinks and wants root:root.
  environment.etc."ssh/sudo_passkeys" = {
    text = "${passkeyWebauthn} rpi5 sudo (ShellWatch)\n";
    mode = "0444";
  };

  environment.systemPackages = [
    shellwatch-agent
    (pkgs.writeShellApplication {
      name = "phone-sudo";
      text = ''
        SSH_AUTH_SOCK=/run/user/$(id -u)/shellwatch-agent.sock exec /run/wrappers/bin/sudo "$@"
      '';
    })
  ];

  # ── Service registration ────────────────────────────────────────────────
  nic.services.shellwatch = {
    backup = [ "unit" ];
    backupUnits = [ "shellwatch-backup.service" ]; # backups.nix
    appUnits = [
      "shellwatch.service"
      "shellwatch-hydra.service"
    ];
    public = {
      order = 900;
      port = 3995;
      backend = "http://127.0.0.1:${toString port}";
    };
  };
}
