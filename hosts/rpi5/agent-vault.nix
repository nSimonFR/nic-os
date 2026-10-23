# hosts/rpi5/agent-vault.nix
#
# Agent Vault (Infisical) — credential broker in front of Hermes' outbound API
# keys. Hermes holds placeholders (`__tavily_api_key__`) and sends its HTTP(S)
# through the MITM proxy on :14322, which swaps in the real value for the hosts
# in `brokered` only, on the surfaces listed there. Everything else passes through.
#
# Not brokered: loopback and *.ts.net stay direct (NO_PROXY), so Aperture, the
# MCPs, HA, Dawarich and Ryot keep their tokens. Hermes runs as nsimon, which can
# still read /run/agenix/agent-env: this stops env/prompt leaks, not a shell.
#
# State is derived: agent-vault-bootstrap re-applies the owner account,
# credentials (from agent-env) and services on every start, so a lost DB is a
# restart. Admin UI (tailnet): owner admin@agent-vault.local, password in
# /run/agenix/agent-vault-admin-password.
{ config, pkgs, ... }:
let
  pkg       = pkgs.callPackage ../../pkgs/services/agent-vault.nix { };
  stateDir  = "/var/lib/agent-vault";
  hermesDir = "/var/lib/agent-vault-hermes";
  apiPort   = 14321;
  proxyPort = 14322;

  # `in` is the security boundary: a placeholder on any other surface is
  # forwarded literally. Each key must exist in agent-env.
  brokered = [
    { name = "tavily";        host = "api.tavily.com";                    keys = [ "TAVILY_API_KEY" ];               "in" = [ "header" "body" ]; }
    { name = "google-places"; host = "places.googleapis.com";             keys = [ "GOOGLE_PLACES_API_KEY" ];        "in" = [ "header" "query" "body" ]; }
    { name = "google-maps";   host = "maps.googleapis.com";               keys = [ "GOOGLE_PLACES_API_KEY" ];        "in" = [ "header" "query" ]; }
    { name = "gemini";        host = "generativelanguage.googleapis.com"; keys = [ "GEMINI_API_KEY" ];               "in" = [ "header" "query" ]; }
    { name = "linear";        host = "api.linear.app";                    keys = [ "LINEAR_KEY" "LINEAR_KEY_TRUSK" ]; "in" = [ "header" ]; }
    { name = "typesafe";      host = "api.typesafe.ai";                   keys = [ "TYPESAFE_API_KEY" ];             "in" = [ "header" ]; }
  ];
  servicesFile = pkgs.writeText "agent-vault-services.json" (builtins.toJSON brokered);
in
{
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

  # Root: reads agent-env and the admin password, writes into nsimon's hermesDir.
  systemd.services.agent-vault-bootstrap = {
    description = "Agent Vault: apply credentials, services and Hermes' proxy env";
    wantedBy = [ "agent-vault.service" ];
    after = [ "agent-vault.service" ];
    partOf = [ "agent-vault.service" ];
    # A re-encrypted agent-env is a new store path, so a rotated key re-applies.
    restartTriggers = [ config.age.secrets.agent-env.file servicesFile ];
    environment = {
      AGENT_VAULT_ADDR = "http://127.0.0.1:${toString apiPort}";
      AGENT_VAULT_PROXY = "127.0.0.1:${toString proxyPort}";
      AGENT_VAULT_ADMIN_EMAIL = "admin@agent-vault.local";
      AGENT_VAULT_ADMIN_PASSWORD_FILE = config.age.secrets.agent-vault-admin-password.path;
      AGENT_VAULT_CREDS_FILE = config.age.secrets.agent-env.path;
      AGENT_VAULT_SERVICES_FILE = "${servicesFile}";
      AGENT_VAULT_OUT_DIR = hermesDir;
      AGENT_VAULT_AGENT = "hermes";
      # Telegram is Hermes' lifeline; .ts.net covers Aperture (the LLM path).
      AGENT_VAULT_NO_PROXY = "api.telegram.org,.ts.net";
      AGENT_VAULT_ON_TOKEN_CHANGE = "${pkgs.systemd}/bin/systemctl --user -M nsimon@ restart hermes.service";
      SYSTEM_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
      AGENT_VAULT_BOOTSTRAP_APPLY = "1";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nicos-scripts}/bin/agent-vault-bootstrap";
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
