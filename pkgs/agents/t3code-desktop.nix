# no-renovate: follows t3code.nix's version; .github/workflows/t3code-fork-release.yml pins the hash.
# The T3 Code desktop app for the Mac, from the nSimonFR-ai/t3code `-issues.N`
# release: the official app with its server and web client rebuilt from the same
# release plus the fork's small changes (its spec.md). Same version as
# ./t3code.nix, which the rpi5 server runs.
# Build it with T3 Connect's public config (T3CODE_RELAY_URL,
# T3CODE_CLERK_PUBLISHABLE_KEY, T3CODE_CLERK_JWT_TEMPLATE,
# T3CODE_CLERK_CLI_OAUTH_CLIENT_ID) or the app runs with T3 Connect off.
#
# Ad-hoc signed and without app-update.yml, so it never updates itself back to
# the official build. Same bundle id as the official app, whose copy in
# /Applications has to go: both would share one data folder.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  t3code,
}:
stdenvNoCC.mkDerivation {
  pname = "t3code-desktop";
  inherit (t3code) version;

  src = fetchurl {
    url = "https://github.com/nSimonFR-ai/t3code/releases/download/v${t3code.version}-issues.1/T3-Code-${t3code.version}-issues-darwin-arm64.zip";
    hash = "sha256-3+72tvKlkMYxQNvp4cAjh4lUxsmJlT6XIxkPSTcpGuM=";
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";

  # Any rewrite of the bundle breaks its signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    cp -R ./*.app $out/Applications/
    runHook postInstall
  '';

  meta = {
    description = "T3 Code desktop app (nic-os fork build)";
    homepage = "https://github.com/nSimonFR-ai/t3code";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
