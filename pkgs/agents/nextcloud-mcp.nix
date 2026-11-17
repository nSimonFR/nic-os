{
  lib,
  callPackage,
  python313,
  inputs,
}:
# nextcloud-mcp-server (cbcoutinho): every locked dependency from upstream's
# uv.lock as a wheel, no extras (semantic search, postgres, OTLP export).
# Served to Aperture by hosts/rpi5/agents/mcp-bridges.nix.
let
  workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = inputs.nextcloud-mcp-src;
  };
  pythonSet =
    (callPackage inputs.pyproject-nix.build.packages { python = python313; }).overrideScope
      (
        lib.composeManyExtensions [
          inputs.pyproject-build-systems.overlays.wheel
          (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
          # urllib3-future (caldav's niquests) installs as `urllib3` too; one copy only.
          (final: _: { urllib3 = final.urllib3-future; })
        ]
      );
in
pythonSet.mkVirtualEnv "nextcloud-mcp-env" workspace.deps.default
