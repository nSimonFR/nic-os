{
  lib,
  callPackage,
  python313,
  writeShellScriptBin,
  inputs,
}:
# mcp4immich (JoeRu): one MCP tool per Immich OpenAPI operation, from upstream's
# uv.lock. Served to Aperture by hosts/rpi5/agents/mcp-bridges.nix.
let
  workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = inputs.mcp4immich-src;
  };
  pythonSet =
    (callPackage inputs.pyproject-nix.build.packages { python = python313; }).overrideScope
      (
        lib.composeManyExtensions [
          inputs.pyproject-build-systems.overlays.wheel
          (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
        ]
      );
  venv = pythonSet.mkVirtualEnv "immich-mcp-env" workspace.deps.default;
in
# Upstream ships no console script, only a top-level main.py module.
writeShellScriptBin "immich-mcp" ''
  exec ${venv}/bin/python -m main "$@"
''
