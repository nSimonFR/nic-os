# DAWNCR0W/affine-mcp-server — write-capable MCP server for AFFiNE workspaces.
#
# Service module (port, secrets oneshot, unit, Serve entry): hosts/rpi5/affine-mcp.nix.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:

buildNpmPackage rec {
  pname = "affine-mcp-server";
  # renovate: datasource=github-releases depName=DAWNCR0W/affine-mcp-server extractVersion=^v(?<version>.+)$
  version = "1.13.0";

  src = fetchFromGitHub {
    # `name` embeds the version on purpose — see pkgs/README.md, "Fixed-output
    # names". Without it the fetch is keyed on (hash, "source"), so a bumped
    # `rev` beside a stale `hash` silently reuses the old tree.
    name = "${pname}-${version}-source";
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
}
