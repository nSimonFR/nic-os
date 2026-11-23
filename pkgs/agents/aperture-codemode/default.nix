# Code Mode MCP over Aperture (Cloudflare's @cloudflare/codemode, run in Node): two tools,
# `search` and `execute`, instead of Aperture's ~400; model code runs in QuickJS (WASM).
# Deps come from package-lock.json (`npm install --ignore-scripts` to refresh it).
{
  lib,
  buildNpmPackage,
  importNpmLock,
  makeWrapper,
  nodejs_24,
}:

buildNpmPackage {
  pname = "aperture-codemode";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
      ./server.mjs
      ./sandbox.mjs
      ./test.mjs
    ];
  };
  nodejs = nodejs_24;
  npmDeps = importNpmLock { npmRoot = ./.; };
  inherit (importNpmLock) npmConfigHook;
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  dontNpmInstall = true;
  nativeBuildInputs = [ makeWrapper ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node --test test.mjs
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/aperture-codemode $out/bin
    cp -r node_modules server.mjs sandbox.mjs package.json $out/lib/aperture-codemode/
    makeWrapper ${lib.getExe nodejs_24} $out/bin/aperture-codemode \
      --add-flags $out/lib/aperture-codemode/server.mjs
    runHook postInstall
  '';

  meta = {
    description = "Code Mode (search + execute) MCP server in front of Aperture's MCP gateway";
    license = lib.licenses.mit;
    mainProgram = "aperture-codemode";
  };
}
