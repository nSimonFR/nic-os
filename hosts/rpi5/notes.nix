# hosts/rpi5/notes.nix
#
# Notes — a plain-markdown folder (/mnt/data/notes) served by OpenKnowledge: web editor,
# live collaboration and an MCP endpoint at /mcp. Replaces AFFiNE.
#
# ⚠ NO AUTHENTICATION: anyone who reaches the port can read and edit every note, and the
#   MCP is unauthenticated too. Tailnet-only (never funnel); shared users are limited to
#   this port by shared/tailscale-acl.json5.
#
# Runs as nsimon because Claude and Hermes edit the same files directly. HOME is the state dir: `open-knowledge start` installs skill bundles into
# $HOME, which must not be ~/.claude.
{ config, pkgs, lib, ... }:
let
  pkg = pkgs.callPackage ../../pkgs/services/open-knowledge { };
  internalPort = 13354;
  notesDir = "/mnt/data/notes";
  stateDir = "/var/lib/open-knowledge";

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
  systemd.tmpfiles.rules = [
    "d ${notesDir} 0750 nsimon users -"
  ];

  systemd.services.open-knowledge = {
    description = "OpenKnowledge — markdown notes editor + MCP";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    unitConfig.RequiresMountsFor = [ notesDir ];

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
        "--external-url ${config.nic.services.notes.public.publicUrl}"
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

  nic.services.notes = {
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
          url = "http://127.0.0.1:8087/notes";
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
