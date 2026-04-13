{ config, pkgs, lib, ... }:
let
  port = 17020;  # internal; Tailscale Serve proxies 7020 → 17020
  affineWorkspaceId = "35d244cd-e6d5-4b3d-b1c2-fa50cab50621";
  affineUrl = "http://127.0.0.1:13010/api/workspaces/${affineWorkspaceId}/mcp";

  supergateway = pkgs.buildNpmPackage rec {
    pname = "supergateway";
    version = "3.4.3";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/supergateway/-/supergateway-${version}.tgz";
      hash = "sha256-0mORmWAmu1lnp36HdHTN/6lDHtWcZRhtVXBk3pj1q4Q=";
    };
    sourceRoot = "package";
    npmDepsHash = "sha256-j/EBbh+0pTmx7nRLh1svV2Rj97sRU7SsZf95ZTbyiM8=";
    postPatch = ''
      cp ${./npm-locks/supergateway-package-lock.json} package-lock.json
    '';
    dontNpmBuild = true;
  };

  # supergateway can't do streamableHttp→sse directly;
  # chain: streamableHttp→stdio (inner) | stdio→sse (outer)
  sg = "${supergateway}/bin/supergateway";
  tokenPath = config.age.secrets.affine-token.path;

  startScript = pkgs.writeShellScript "affine-mcp-gateway" ''
    TOKEN=$(cat ${tokenPath} 2>/dev/null || true)
    BEARER_ARGS=""
    if [ -n "$TOKEN" ]; then
      BEARER_ARGS="--oauth2Bearer $TOKEN"
    fi
    exec ${sg} \
      --stdio "${sg} --streamableHttp ${affineUrl} $BEARER_ARGS" \
      --port ${toString port} \
      --ssePath /sse \
      --messagePath /message
  '';
in
{
  systemd.services.affine-mcp-gateway = {
    description = "Supergateway: AFFiNE streamable-http → SSE";
    after = [ "network-online.target" "affine.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "5s";
      ExecStart = startScript;
    };
  };
}
