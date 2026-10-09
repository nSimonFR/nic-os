# The T3 Code desktop app for the Mac, from the nSimonFR-ai/t3code `-issues.N`
# release: the official nightly app with its server and web client rebuilt from
# the nightly plus pingdotgg/t3code#6315 (Issues page, Linear trees) and
# #15827 + #17432 (Claude Code mod UI and mod commands). Same version as
# ./t3code.nix, which the rpi5 server runs.
# Build it with T3 Connect's public config (T3CODE_RELAY_URL,
# T3CODE_CLERK_PUBLISHABLE_KEY, T3CODE_CLERK_JWT_TEMPLATE,
# T3CODE_CLERK_CLI_OAUTH_CLIENT_ID) or the app runs with T3 Connect off.
#
# Ad-hoc signed and without app-update.yml, so it never updates itself back to
# the official nightly. Same bundle id as the official "T3 Code (Nightly)" app,
# whose copy in /Applications has to go: both would share one data folder.
{ lib
, stdenvNoCC
, fetchurl
, unzip
, t3code
}:
stdenvNoCC.mkDerivation {
  pname = "t3code-desktop";
  inherit (t3code) version;

  src = fetchurl {
    url = "https://github.com/nSimonFR-ai/t3code/releases/download/v${t3code.version}-issues.1/T3-Code-${t3code.version}-issues-darwin-arm64.zip";
    hash = "sha256-2mGPrNAIPGRiSQlbS8pPKcm7YkDVBZvMlD4wQHqO+j8=";
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";

  # Any rewrite of the bundle breaks its signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    cp -R "T3 Code (Nightly).app" $out/Applications/
    runHook postInstall
  '';

  meta = {
    description = "T3 Code desktop app (nightly with the Issues page)";
    homepage = "https://github.com/nSimonFR-ai/t3code";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
