# codex-proxy (icebear0828/codex-proxy v2.0.64) — OpenAI-compatible proxy
# using ChatGPT/Codex OAuth tokens with proper token counts and tool_calls.
#
# Replaces openai-oauth (EvanZhouDev/openai-oauth v1.0.2) which had:
#   - Zero token counts (Vercel AI SDK v6 specificationVersion mismatch)
#   - Broken tool_calls (unmerged PRs #6, #8, #11)
#
# Pre-built at /opt/codex-proxy/ (includes native Rust TLS addon for aarch64).
# Runtime data (accounts, cookies) persisted in the service working directory.
# Login via web UI at http://127.0.0.1:4040 or import existing tokens.
{ pkgs, username, ... }:
let
  port      = 4040;
  installDir = "/opt/codex-proxy";
  stateDir   = "/var/lib/codex-proxy";
in
{
  systemd.services.openai-codex-proxy = {
    description = "OpenAI-compatible proxy via ChatGPT OAuth (codex-proxy)";
    after       = [ "network.target" ];
    wantedBy    = [ "multi-user.target" ];

    # Set up symlink-based working directory: immutable code from /opt,
    # mutable data/ for account persistence and config overrides.
    preStart = ''
      mkdir -p ${stateDir}/data

      # Symlink immutable assets from the install directory
      for item in dist native node_modules config public package.json bin; do
        [ -e ${installDir}/$item ] && ln -sfn ${installDir}/$item ${stateDir}/$item
      done

      # Create local config if missing (host/port/disable auto-update)
      if [ ! -f ${stateDir}/data/local.yaml ]; then
        cat > ${stateDir}/data/local.yaml << 'YAML'
      server:
        host: "127.0.0.1"
        port: ${toString port}
      update:
        auto_update: false
      YAML
      fi
    '';

    serviceConfig = {
      Type             = "simple";
      User             = username;
      WorkingDirectory = stateDir;
      ExecStart        = "${pkgs.nodejs_22}/bin/node ${stateDir}/dist/index.js";
      Restart          = "on-failure";
      RestartSec       = "5s";

      # Hardening
      NoNewPrivileges  = true;
      ProtectSystem    = "strict";
      ReadWritePaths   = [ stateDir ];
      ProtectHome      = true;
    };

    environment = {
      NODE_ENV = "production";
      PORT     = toString port;
    };
  };

  # Ensure the state directory exists with correct ownership
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 ${username} users -"
    "d ${stateDir}/data 0750 ${username} users -"
  ];
}
