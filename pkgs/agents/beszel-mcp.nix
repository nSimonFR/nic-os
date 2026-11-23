# beszel-mcp (github.com/maxbth/beszel-mcp, MIT): read-only MCP server for a Beszel hub,
# run from its TypeScript sources by Bun. Stands in for the hub's own MCP (beszel#2816,
# unreleased after 0.21.2); drop it once the hub ships that.
# ⚠ HASH: node_modules is a fixed-output `bun install`; after a source bump set
#   outputHash to lib.fakeHash, build once and paste the `got:`.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  writeShellScript,
}:
let
  pname = "beszel-mcp";
  version = "0.1.0-unstable-2026-08-28";
  # no-renovate: upstream has no tags or releases; a bump also needs the node_modules hash
  src = fetchFromGitHub {
    owner = "maxbth";
    repo = "beszel-mcp";
    rev = "76f4a57787cec777175b26e0536946534b26953f";
    hash = "sha256-YYIEj56xcUlDP5SuMsBpeaf8ONeG0ntki1vtzFwWb88=";
  };

  # Pure-JS production deps only, so one hash fits every platform.
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version src;
    nativeBuildInputs = [ bun ];
    dontConfigure = true;
    buildPhase = ''
      export HOME=$TMPDIR
      bun install --production --frozen-lockfile --ignore-scripts --no-progress
    '';
    installPhase = ''
      rm -rf node_modules/.cache
      cp -r node_modules $out
    '';
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-KCNYnL98BQS4M04/4oXNAJsss2NRF/fGN388k2Gj2WQ=";
  };
in
stdenvNoCC.mkDerivation {
  inherit pname version src;
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/lib/beszel-mcp $out/bin
    cp -r src package.json $out/lib/beszel-mcp/
    cp -r ${nodeModules} $out/lib/beszel-mcp/node_modules
    install -Dm755 ${writeShellScript "beszel-mcp" ''
      exec ${lib.getExe bun} --no-install run @out@/lib/beszel-mcp/src/index.ts "$@"
    ''} $out/bin/beszel-mcp
    substituteInPlace $out/bin/beszel-mcp --replace-fail @out@ $out
  '';
  meta = {
    description = "Read-only MCP server for a Beszel monitoring hub";
    homepage = "https://github.com/maxbth/beszel-mcp";
    license = lib.licenses.mit;
    mainProgram = "beszel-mcp";
  };
}
