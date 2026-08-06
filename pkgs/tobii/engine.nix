# Main Tobii Engine daemon (face tracking, calibration, firmware).
# Repackaged from the Arch packages at
# https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer
#
# Ships $out/share/tobii_engine; the unit copies it into a writable StateDirectory
# because the daemon writes config.db next to its binary. See nixos/tobii-native.nix.
{
  stdenv,
  autoPatchelfHook,
  fetchurl,
  libgcc,
  sqlcipher,
  zlib,
  zstd,
}:

stdenv.mkDerivation {
  pname = "tobii-engine";
  version = "0.1.6.193rc";

  src = fetchurl {
    url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobii_engine_linux-0.1.6.193rc-1-x86_64.pkg.tar.zst";
    hash = "sha256-duCqFXZk7grNIsRK/4vu4EAkCZAmkYtcUrk8pKh9QcE=";
  };

  nativeBuildInputs = [ autoPatchelfHook zstd ];
  buildInputs = [
    stdenv.cc.cc.lib # libstdc++
    zlib             # libz
    sqlcipher        # libsqlcipher
    libgcc           # libgomp (via libseeta)
  ];

  unpackPhase = ''
    tar xf $src
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share
    cp -r usr/share/tobii_engine $out/share/tobii_engine

    # Add bundled libs to rpath so self-referential deps resolve
    addAutoPatchelfSearchPath $out/share/tobii_engine/lib
    addAutoPatchelfSearchPath $out/share/tobii_engine/platform_modules
    runHook postInstall
  '';
}
