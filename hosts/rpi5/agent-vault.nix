# hosts/rpi5/agent-vault.nix
#
# Agent Vault (Infisical) — credential broker in front of Hermes' outbound API
# keys. Hermes holds placeholders (`__tavily_api_key__`) and sends its HTTP(S)
# through the MITM proxy on :14322, which swaps in the real value for the hosts
# in `brokered` only, on the surfaces listed there. Everything else passes through.
#
# The keys live in agent-brokered-env, root-only; agents (Hermes via its
# execWrapper, skills by sourcing proxy.env) see only the placeholders.
# Loopback and *.ts.net stay direct (NO_PROXY), so Aperture and the MCPs are
# untouched; local services are brokered under a *.home.arpa alias instead.
#
# GitHub is the other way round: Agent Vault attaches nSimonFR-ai's token itself
# (github-ai-token, root-only), so agents hold nothing at all. Every git on the
# box reaches github.com through it (hermesDir/gitconfig, included from
# ~/.config/git), and the rpi5 `gh` wrapper sources proxy.env. nsimon has
# passwordless sudo, so this stops an echoed token, not a determined agent.
#
# State is derived: agent-vault-bootstrap re-applies the owner account,
# credentials and services on every start, so a lost DB is a
# restart. Admin UI (tailnet): owner admin@agent-vault.local, password in
# /run/agenix/agent-vault-admin-password.
{ config, lib, pkgs, ... }:
let
  pkg       = pkgs.callPackage ../../pkgs/services/agent-vault.nix { };
  stateDir  = "/var/lib/agent-vault";
  hermesDir = "/var/lib/agent-vault-hermes";
  apiPort   = 14321;
  proxyPort = 14322;

  # `in` is the security boundary: a placeholder on any other surface is
  # forwarded literally. Each key must exist in agent-brokered-env or credFiles.
  brokered = [
    { name = "tavily";        host = "api.tavily.com";                    keys = [ "TAVILY_API_KEY" ];               "in" = [ "header" "body" ]; }
    { name = "google-places"; host = "places.googleapis.com";             keys = [ "GOOGLE_PLACES_API_KEY" ];        "in" = [ "header" "query" "body" ]; }
    { name = "google-maps";   host = "maps.googleapis.com";               keys = [ "GOOGLE_PLACES_API_KEY" ];        "in" = [ "header" "query" ]; }
    { name = "gemini";        host = "generativelanguage.googleapis.com"; keys = [ "GEMINI_API_KEY" ];               "in" = [ "header" "query" ]; }
    { name = "linear";        host = "api.linear.app";                    keys = [ "LINEAR_KEY" "LINEAR_KEY_TRUSK" ]; "in" = [ "header" ]; }
    { name = "typesafe";      host = "api.typesafe.ai";                   keys = [ "TYPESAFE_API_KEY" ];             "in" = [ "header" ]; }
    # Loopback services: the alias resolves to 127.0.0.1 (networking.hosts below).
    { name = "home-assistant"; host = "ha.home.arpa:8123";        keys = [ "HA_TOKEN" ];         "in" = [ "header" ]; }
    { name = "dawarich";       host = "dawarich.home.arpa:13900"; keys = [ "DAWARICH_API_KEY" ]; "in" = [ "header" "query" ]; }
    # Ryot V2 (ryot.nix): REST under /api, key sent as `X-Api-Key`.
    { name = "ryot";           host = "ryot.home.arpa:13350";     keys = [ "RYOT_API_KEY" ];     "in" = [ "header" ]; }
    { name = "immich";         host = "immich.home.arpa:2283";    keys = [ "IMMICH_API_KEY" ];   "in" = [ "header" ]; }
    # Attached, not substituted: whatever the client sends is replaced.
    { name = "github-api";     host = "api.github.com";     auth = { type = "bearer"; token = "GITHUB_AI_TOKEN"; }; }
    { name = "github-uploads"; host = "uploads.github.com"; auth = { type = "bearer"; token = "GITHUB_AI_TOKEN"; }; }
    { name = "github-git";     host = "github.com";         auth = { type = "basic"; username = "GITHUB_GIT_USER"; password = "GITHUB_AI_TOKEN"; }; }
    # Read routes only: /api/v2/deploy/activate matches neither, so agents can't
    # deploy with it (no method filter, so POST /logs is still reachable).
    { name = "cachix-deployment"; host = "app.cachix.org/api/v1/deploy/deployment/*"; auth = { type = "bearer"; token = "CACHIX_ACTIVATE_TOKEN"; }; }
    { name = "cachix-logs";       host = "app.cachix.org/api/v1/deploy/logs/*";       auth = { type = "bearer"; token = "CACHIX_ACTIVATE_TOKEN"; }; }
  ];
  credFiles = {
    IMMICH_API_KEY = config.age.secrets.immich-api-key.path;
    # Minted by ryot-bootstrap (ryot.nix), which re-runs this unit on a new key.
    RYOT_API_KEY = "-/var/lib/ryot-v2/secrets/api-key";
    GITHUB_AI_TOKEN = config.age.secrets.github-ai-token.path;
    GITHUB_GIT_USER = pkgs.writeText "github-git-user" "x-access-token";
    CACHIX_ACTIVATE_TOKEN = config.age.secrets.cachix-activate-token.path;
  };
  servicesFile = pkgs.writeText "agent-vault-services.json" (builtins.toJSON brokered);
in
{
  networking.hosts."127.0.0.1" = map (s: lib.head (lib.splitString ":" s.host))
    (lib.filter (s: lib.hasSuffix ".home.arpa" (lib.head (lib.splitString ":" s.host))) brokered);

  users.users.agent-vault = {
    isSystemUser = true;
    group = "agent-vault";
  };
  users.groups.agent-vault = { };

  systemd.tmpfiles.rules = [ "d ${hermesDir} 0700 nsimon users -" ];

  systemd.services.agent-vault = {
    description = "Agent Vault credential broker";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      HOME = stateDir; # data lives in $HOME/.agent-vault
      AGENT_VAULT_ADDR = config.nic.services.agent-vault.public.publicUrl;
      AGENT_VAULT_TELEMETRY = "false";
      # Hermes reaches tailnet and LAN hosts through the proxy too; only local
      # clients can use it. Cloud metadata stays blocked regardless.
      AGENT_VAULT_ALLOW_PRIVATE_RANGES = "true";
      AGENT_VAULT_LOGS_MAX_AGE_HOURS = "72";
    };
    serviceConfig = {
      User = "agent-vault";
      Group = "agent-vault";
      EnvironmentFile = config.age.secrets.agent-vault-env.path;
      ExecStart = "${pkg}/bin/agent-vault server --host 127.0.0.1 --port ${toString apiPort} --mitm-port ${toString proxyPort}";
      StateDirectory = "agent-vault";
      StateDirectoryMode = "0700";
      # Hermes' outbound HTTPS dies with it; earlyoom's SIGTERM exits 0.
      Restart = "always";
      RestartSec = "5";

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # Root: reads the brokered keys and the admin password, writes into nsimon's hermesDir.
  systemd.services.agent-vault-bootstrap = {
    description = "Agent Vault: apply credentials, services and Hermes' proxy env";
    wantedBy = [ "agent-vault.service" ];
    after = [ "agent-vault.service" ];
    partOf = [ "agent-vault.service" ];
    # A re-encrypted secret is a new store path, so a rotated key re-applies.
    restartTriggers = [
      config.age.secrets.agent-brokered-env.file config.age.secrets.github-ai-token.file
      config.age.secrets.immich-api-key.file config.age.secrets.cachix-activate-token.file
      servicesFile
    ];
    environment = {
      AGENT_VAULT_ADDR = "http://127.0.0.1:${toString apiPort}";
      AGENT_VAULT_PROXY = "127.0.0.1:${toString proxyPort}";
      AGENT_VAULT_ADMIN_EMAIL = "admin@agent-vault.local";
      AGENT_VAULT_ADMIN_PASSWORD_FILE = config.age.secrets.agent-vault-admin-password.path;
      AGENT_VAULT_CREDS_FILE = config.age.secrets.agent-brokered-env.path;
      AGENT_VAULT_CRED_FILES = lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=${v}") credFiles);
      AGENT_VAULT_SERVICES_FILE = "${servicesFile}";
      AGENT_VAULT_OUT_DIR = hermesDir;
      # Telegram is Hermes' lifeline; .ts.net covers Aperture (the LLM path).
      AGENT_VAULT_NO_PROXY = "api.telegram.org,.ts.net";
      SYSTEM_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
      AGENT_VAULT_BOOTSTRAP_APPLY = "1";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nicos-scripts}/bin/agent-vault-bootstrap";
    };
  };

  # Hermes reads proxy.env only at start; bootstrap rewrites it only on change.
  systemd.paths.agent-vault-hermes-restart = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = "${hermesDir}/proxy.env";
  };
  systemd.services.agent-vault-hermes-restart = {
    description = "Restart Hermes onto a new Agent Vault proxy env";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl --user -M nsimon@ restart hermes.service";
    };
  };

  nic.services.agent-vault = {
    backup = [ "none" ];
    backupNote =
      "derived — agent-vault-bootstrap rebuilds credentials, services and the "
      + "Hermes token from agenix and this module; only the 72h request log is lost";
    # ~27 MB idle, and Hermes' outbound HTTPS depends on it.
    heavyUnits = [ ];

    public = {
      order = 305;
      port = 3990;
      backend = "http://127.0.0.1:${toString apiPort}";
      tile = {
        name = "Agent Vault";
        icon = "mdi-shield-key";
        category = "Backend";
        description = "Hermes' API keys";
      };
    };
  };
}
