# hosts/rpi5/open-knowledge.nix
#
# OpenKnowledge serving the markdown notes in the Nextcloud folder (/mnt/data/cloud/NOTES):
# web editor, live collaboration and an MCP endpoint at /mcp. Replaces AFFiNE.
#
# ⚠ NO AUTHENTICATION: anyone who reaches the port can read and edit every note, and the
#   MCP is unauthenticated too. Tailnet-only (never funnel); shared users are limited to
#   this port by shared/tailscale-acl.json5.
#
# Runs as nsimon because Claude and Hermes edit the same files directly. HOME is the state dir: `open-knowledge start` installs skill bundles into
# $HOME, which must not be ~/.claude.
#
# The editor's agent panel runs Claude through ACP (`npx -y @agentclientprotocol/claude-agent-acp`,
# inheriting this unit's env): it talks to Aperture like Cyrus, the gate injects the OAuth
# token, and CLAUDE_CODE_EXECUTABLE swaps the SDK's downloaded binary for the Nix one.
{ config, pkgs, lib, unstablePkgs, apertureUrl, ... }:
let
  pkg = pkgs.callPackage ../../pkgs/services/open-knowledge { };
  internalPort = 13354;
  notesDir = "/mnt/data/cloud/NOTES";
  occ = "${config.services.nextcloud.occ}/bin/nextcloud-occ";
  stateDir = "/var/lib/open-knowledge";
  claudeCode = pkgs.callPackage ../../pkgs/agents/claude-code.nix {
    inherit (unstablePkgs) claude-code;
  };

  # Telemetry: no remote export without OTEL_* vars; this also stops the local span log,
  # which otherwise grows inside the notes folder (.ok/local/telemetry, ~34 MB in a week).
  globalConfig = pkgs.writeText "open-knowledge-global.yml" ''
    telemetry:
      localSink:
        enabled: false
      skillInstallReports:
        enabled: false
  '';
in
{
  systemd.services.open-knowledge = {
    description = "OpenKnowledge — markdown notes editor + MCP";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    # /mnt/data/cloud is a bind mount of the Nextcloud files dir (nextcloud.nix).
    unitConfig.RequiresMountsFor = [ notesDir ];
    # npx launches the ACP agent; rg replaces claude's vendored one (4K-page jemalloc aborts here).
    path = [ pkgs.nodejs_24 pkgs.ripgrep pkgs.git ];

    environment = {
      HOME = stateDir;
      XDG_CONFIG_HOME = "${stateDir}/.config";
      XDG_CACHE_HOME = "${stateDir}/.cache";
      XDG_DATA_HOME = "${stateDir}/.local/share";
      XDG_STATE_HOME = "${stateDir}/.local/state";
      DO_NOT_TRACK = "1";
      DISABLE_TELEMETRY = "1";
      # Required to serve on the tailnet URL; reachability is gated by Tailscale instead.
      OK_ALLOW_EXTERNAL = "1";
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      CLAUDE_CODE_EXECUTABLE = lib.getExe claudeCode;
      USE_BUILTIN_RIPGREP = "0";
      ANTHROPIC_BASE_URL = apertureUrl;
      ANTHROPIC_API_KEY = "injected-by-tiny-llm-gate";
      CLAUDE_CODE_ENABLE_TELEMETRY = "0";
    };

    serviceConfig = {
      Type = "simple";
      User = "nsimon";
      Group = "users";
      StateDirectory = "open-knowledge";
      WorkingDirectory = notesDir;
      ExecStartPre = "${pkgs.coreutils}/bin/install -D -m 0644 ${globalConfig} ${stateDir}/.ok/global.yml";
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkg)
        "start"
        "--bind 127.0.0.1"
        "-p ${toString internalPort}"
        "--no-open-browser"
        "--idle-shutdown off"
        "--external-url ${config.nic.services.open-knowledge.public.publicUrl}"
      ];
      # earlyoom's SIGTERM ends it with exit 0, which on-failure would not restart.
      Restart = "always";
      RestartSec = "10";

      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ notesDir ];
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # Files written here (editor, agents) stay invisible to Nextcloud's apps until scanned;
  # the folder is small (~1k files, ~3 s).
  systemd.services.open-knowledge-nc-scan = {
    description = "Index the notes folder into Nextcloud";
    after = [ "phpfpm-nextcloud.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${occ} files:scan --path /nsimon/files/NOTES --quiet";
    };
  };
  systemd.timers.open-knowledge-nc-scan = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
    };
  };

  nic.services.open-knowledge = {
    backup = [ "mnt-data" ];
    heavyUnits = [ "open-knowledge.service" ];
    heavyPriority = 70;

    # Completes the "rest" row while AFFiNE still holds order 70.
    public = {
      order = 240;
      port = 3980;
      backend = "http://127.0.0.1:${toString internalPort}";
      tile = {
        name = "Notes";
        icon = "mdi-notebook-outline";
        category = "Apps";
        description = "Markdown notes & wiki (OpenKnowledge)";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/openknowledge";
          refreshInterval = 3600000;
          mappings = [
            { field = "docs"; label = "Docs"; format = "number"; }
            { field = "edited_7d"; label = "Edited 7d"; format = "number"; }
            { field = "storage"; label = "Storage"; format = "bytes"; }
          ];
        };
      };
    };
  };
}
