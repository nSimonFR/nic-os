# linear-t3-relay — Linear Agent Sessions → T3 Code over its outside-agent MCP
# server (nSimonFR/linear-t3-relay). No runtime dependencies: the npm deps are
# the TypeScript toolchain, dropped after `tsc`.
{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_22,
  linear-t3-relay-src,
}:
buildNpmPackage {
  pname = "linear-t3-relay";
  version = "0-unstable-${linear-t3-relay-src.shortRev or "dirty"}";
  src = linear-t3-relay-src;
  nodejs = nodejs_22;
  nativeBuildInputs = [ makeWrapper ];

  npmDepsHash = "sha256-G11RGsBOEXK/0yaNeNl9kn+QFRnYEm/TZKdCmUE0g6g=";

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';

  # Ship only the compiled JS; the bins are package.json's.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/linear-t3-relay $out/bin
    cp -r dist package.json $out/lib/linear-t3-relay/
    for bin in linear-t3-relay:server linear-t3-relay-login:t3-login; do
      makeWrapper ${lib.getExe nodejs_22} $out/bin/''${bin%%:*} \
        --add-flags $out/lib/linear-t3-relay/dist/''${bin##*:}.js
    done
    runHook postInstall
  '';

  meta = {
    description = "Delegate Linear issues to T3 Code";
    homepage = "https://github.com/nSimonFR/linear-t3-relay";
    license = lib.licenses.mit;
    mainProgram = "linear-t3-relay";
  };
}
