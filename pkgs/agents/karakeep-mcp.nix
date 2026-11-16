# karakeep-mcp — Karakeep's official MCP server (apps/mcp), stdio only. Built
# from the same source and pnpm deps as nixpkgs' karakeep, so it follows that
# package's version with no hash of its own; vite bundles every dependency.
{
  karakeep,
  nodejs_22,
  writeShellScript,
}:
karakeep.overrideAttrs (old: {
  pname = "karakeep-mcp";
  inherit (old) pnpmDeps;

  buildPhase = ''
    runHook preBuild
    pushd apps/mcp
    pnpm run build
    popd
    runHook postBuild
  '';

  preInstall = "";
  postFixup = "";
  installPhase = ''
    runHook preInstall
    install -Dm644 apps/mcp/dist/index.js $out/lib/karakeep-mcp/index.js
    install -Dm755 ${writeShellScript "karakeep-mcp" ''
      exec ${nodejs_22}/bin/node @out@/lib/karakeep-mcp/index.js "$@"
    ''} $out/bin/karakeep-mcp
    substituteInPlace $out/bin/karakeep-mcp --replace-fail @out@ $out
    runHook postInstall
  '';

  doInstallCheck = false;
  passthru = { };
  meta = old.meta // {
    description = "MCP server for Karakeep";
    mainProgram = "karakeep-mcp";
  };
})
