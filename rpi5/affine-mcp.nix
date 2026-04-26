# DAWNCR0W/affine-mcp-server — write-capable MCP for AFFiNE.
#
# AFFiNE 0.26.6's built-in MCP at /api/workspaces/<wid>/mcp exposes only 3
# read tools (read_document, semantic_search, keyword_search). Issue
# toeverything/AFFiNE#14161 tracks adding writes upstream — not yet shipped.
# This service runs DAWNCR0W's third-party MCP locally and tiny-llm-gate's
# affine bridge proxies to it instead of the native endpoint.
{ config, lib, pkgs, ... }:
let
  port = 7021;

  affineMcpServer = pkgs.buildNpmPackage rec {
    pname = "affine-mcp-server";
    version = "1.13.0";

    src = pkgs.fetchFromGitHub {
      owner = "DAWNCR0W";
      repo = "affine-mcp-server";
      rev = "v${version}";
      hash = "sha256-Eqod6cSJCw7cuR4He7fierBAs8i3wjSCnc7MSUn3RRU=";
    };

    npmDepsHash = "sha256-WderlJSCLaAkPa3LV7IG/m5fGzDRqDBDPVyrEOneLk4=";

    # The package's "build" script runs `tsc -p tsconfig.json`. buildNpmPackage
    # invokes `npm run build` automatically; the resulting dist/ + bin/ are
    # what `bin/affine-mcp` exec into.
    npmBuildScript = "build";

    # Tests pull in playwright + a live AFFiNE; skip during package build.
    dontNpmInstall = false;
    doCheck = false;

    meta = with lib; {
      description = "MCP server for AFFiNE workspaces (write-capable)";
      homepage = "https://github.com/DAWNCR0W/affine-mcp-server";
      license = licenses.mit;
      mainProgram = "affine-mcp";
    };
  };
in
{
  # Oneshot generates the EnvironmentFile holding the AFFiNE token + the bearer
  # secret tiny-llm-gate uses to authenticate to this server. Same pattern as
  # rpi5/homepage.nix:60-78 (homepage-dashboard-env.service).
  systemd.services.affine-mcp-env = {
    description = "Generate affine-mcp environment file with secrets";
    wantedBy = [ "multi-user.target" ];
    before = [ "affine-mcp.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/affine-mcp
      cat > /run/affine-mcp/env <<ENVEOF
      MCP_TRANSPORT=http
      AFFINE_BASE_URL=http://127.0.0.1:13010
      AFFINE_API_TOKEN=$(cat ${config.age.secrets.affine-token.path})
      AFFINE_MCP_AUTH_MODE=bearer
      AFFINE_MCP_HTTP_TOKEN=$(cat ${config.age.secrets.affine-mcp-http-token.path})
      AFFINE_MCP_HTTP_HOST=127.0.0.1
      PORT=${toString port}
      ENVEOF
      chmod 0400 /run/affine-mcp/env
    '';
  };

  systemd.services.affine-mcp = {
    description = "AFFiNE MCP server (DAWNCR0W) — write-capable bridge";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "affine.service" "affine-mcp-env.service" ];
    wants = [ "affine.service" ];
    requires = [ "affine-mcp-env.service" ];

    serviceConfig = {
      DynamicUser = true;
      RuntimeDirectory = "affine-mcp";
      EnvironmentFile = "/run/affine-mcp/env";
      ExecStart = "${pkgs.nodejs_22}/bin/node ${affineMcpServer}/lib/node_modules/affine-mcp-server/dist/index.js";
      Restart = "on-failure";
      RestartSec = 5;
      MemoryMax = "192M";

      # Hardening — DAWNCR0W only needs network + read access to its own
      # node_modules; everything else can be sandboxed.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };
}
