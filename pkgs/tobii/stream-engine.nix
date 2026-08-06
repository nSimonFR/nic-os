# Shared library + headers for the Tobii Stream Engine API.
# Repackaged from https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer
{
  stdenv,
  autoPatchelfHook,
  avahi,
  fetchurl,
}:

stdenv.mkDerivation {
  pname = "tobii-stream-engine";
  version = "4.24.0";

  src = fetchurl {
    url = "https://raw.githubusercontent.com/megagtrwrath/tobii_eye_tracker_linux_installer/master/tobii-stream-engine-4.24.0-linux-x86_64.tar.gz";
    hash = "sha256-dItQCNLAkau14zL/dvpifynWrNc8HIVRM0O4+oFY6zA=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    stdenv.cc.cc.lib
    avahi # libavahi-client, libavahi-common
  ];

  sourceRoot = "tobii-stream-engine-4.24.0";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include/tobii
    cp lib/libtobii_stream_engine.so $out/lib/
    # The .so has SONAME=libtobii_research.so; create the alias so the
    # dynamic linker and autoPatchelfHook can find it by its SONAME.
    ln -s $out/lib/libtobii_stream_engine.so $out/lib/libtobii_research.so
    cp include/tobii/*.h $out/include/tobii/
    runHook postInstall
  '';
}
