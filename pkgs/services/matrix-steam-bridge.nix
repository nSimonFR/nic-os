# Steam chat bridge (jasonlaguidice/matrix-steam-bridge): a Go bridgev2 binary that
# spawns a C# gRPC service (SteamKit2). The Go half is built from source with goolm
# (the release binary links nixpkgs' insecure-flagged libolm); the C# half has no
# practical source build here (.NET 10 + NuGet), so it is the release's
# self-contained single-file binary, patched for NixOS.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  fetchurl,
  stdenvNoCC,
  autoPatchelfHook,
  makeWrapper,
  openssl,
  stdenv,
}:
let
  # renovate: datasource=github-releases depName=jasonlaguidice/matrix-steam-bridge extractVersion=^v(?<version>.+)$
  version = "1.5.0";

  src = fetchFromGitHub {
    name = "matrix-steam-bridge-${version}-source";
    owner = "jasonlaguidice";
    repo = "matrix-steam-bridge";
    rev = "v${version}";
    hash = "sha256-y7RBcxUceKu+6W3LlyRRGy3ctkhXmV26s+yYkdSB1NI=";
  };

  releaseTarball = fetchurl {
    name = "matrix-steam-bridge-${version}-linux-arm64.tar.gz";
    url = "https://github.com/jasonlaguidice/matrix-steam-bridge/releases/download/v${version}/matrix-steam-bridge-linux-arm64.tar.gz";
    hash = "sha256-kX+iIbyvBE/Aq9vrbTA2GM4H/nP7nDkMepOAZaM6IW4=";
  };

  # Patched in place: the single-file bundle survives patchelf (checked on rpi5).
  # libssl is dlopen'ed at runtime, so it comes through LD_LIBRARY_PATH.
  steamkit-service = stdenvNoCC.mkDerivation {
    pname = "steamkit-service";
    inherit version;
    src = releaseTarball;
    nativeBuildInputs = [
      autoPatchelfHook
      makeWrapper
    ];
    buildInputs = [ stdenv.cc.cc.lib ];
    dontStrip = true; # strip would drop the appended bundle
    installPhase = ''
      install -Dm755 steamkit-service $out/libexec/steamkit-service
      makeWrapper $out/libexec/steamkit-service $out/bin/steamkit-service \
        --set DOTNET_SYSTEM_GLOBALIZATION_INVARIANT 1 \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ openssl ]}
    '';
    meta = {
      description = "Matrix Steam bridge's SteamKit2 gRPC service (upstream release binary)";
      homepage = "https://github.com/jasonlaguidice/matrix-steam-bridge";
      platforms = [ "aarch64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };
in
buildGoModule {
  pname = "matrix-steam-bridge";
  inherit version src;
  vendorHash = "sha256-rPr8nQg0JErydlENFE4fUZOb6+xE2LSHJfyBA+s+V3k=";

  subPackages = [ "cmd/steam" ];
  tags = [ "goolm" ];
  doCheck = false;

  passthru = { inherit steamkit-service; };

  meta = {
    description = "Matrix-Steam chat puppeting bridge (mautrix-go bridgev2)";
    homepage = "https://github.com/jasonlaguidice/matrix-steam-bridge";
    mainProgram = "steam";
    platforms = [ "aarch64-linux" ];
  };
}
