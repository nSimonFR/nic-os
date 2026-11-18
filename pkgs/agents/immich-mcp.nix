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
          # Its docs://usage-guide resource reads site-packages/docs/usage-guide.md,
          # which setuptools does not install.
          (final: prev: {
            mcp4immich = prev.mcp4immich.overrideAttrs (old: {
              postInstall = (old.postInstall or "") + ''
                install -Dm644 ${inputs.mcp4immich-src}/docs/usage-guide.md \
                  $out/${final.python.sitePackages}/docs/usage-guide.md
              '';
            });
          })
        ]
      );
  venv = pythonSet.mkVirtualEnv "immich-mcp-env" workspace.deps.default;
in
# Upstream ships no console script, only a top-level main.py module.
writeShellScriptBin "immich-mcp" ''
  exec ${venv}/bin/python -m main "$@"
''
