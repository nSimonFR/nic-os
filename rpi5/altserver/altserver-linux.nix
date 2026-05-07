{ stdenv, fetchurl, lib }:
# nixpkgs ships altserver-linux but hardcodes the x86_64 release asset; this
# fetches the aarch64 prebuilt from the same upstream release. The binary is
# fully static (verified with `file`), so no patchelf or runtime libs needed.
stdenv.mkDerivation (finalAttrs: {
  pname = "altserver-linux";
  version = "0.0.5";

  src = fetchurl {
    url = "https://github.com/NyaMisty/AltServer-Linux/releases/download/v${finalAttrs.version}/AltServer-aarch64";
    sha256 = "0afyyfjp6vn9z2k8fj1311d5zhsaxkb6f685a8i3h3dm8jm20q48";
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/alt-server
    runHook postInstall
  '';

  meta = with lib; {
    description = "AltServer for AltStore (aarch64 prebuilt)";
    homepage = "https://github.com/NyaMisty/AltServer-Linux";
    license = licenses.unfree;
    platforms = [ "aarch64-linux" ];
    mainProgram = "alt-server";
  };
})
