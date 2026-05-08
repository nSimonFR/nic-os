{ lib
, fetchFromGitHub
, buildDubPackage
, ldc
, clang
, pkg-config
, openssl
, zlib
, cacert
, libplist
, makeWrapper
}:
# Adapted from SZanko/nur-packages (pkgs/anisette-v3-server). Upstream
# Dadoum/anisette-v3-server ships no releases or tags, only a Docker image.
# SZanko's fork pins a known-buildable rev with a regenerated dub lock.
# We piggyback on it; if upstream ever cuts a release we'll repoint src.
buildDubPackage {
  pname = "anisette-v3-server";
  version = "unstable-2026-01-15";

  src = fetchFromGitHub {
    owner = "SZanko";
    repo = "anisette-v3-server";
    rev = "3f96c999330c94141221e31631553ab37d87b725";
    hash = "sha256-+Z5rfLFKTCY2Nb0G9edl/iZsiWIRkS9Ooo6uqJdmQ8A=";
  };

  dubLock = ./dub-lock.json;
  compiler = ldc;
  dubBuildType = "release";

  nativeBuildInputs = [ ldc clang pkg-config makeWrapper ];
  buildInputs = [ openssl zlib libplist ];
  propagatedBuildInputs = [ cacert ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 anisette-v3-server $out/bin/.anisette-v3-server-unwrapped
    makeWrapper $out/bin/.anisette-v3-server-unwrapped $out/bin/anisette-v3-server \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ libplist openssl zlib ]}"
    runHook postInstall
  '';

  meta = {
    description = "SideStore-compatible anisette v3 server";
    homepage = "https://github.com/Dadoum/anisette-v3-server";
    license = lib.licenses.unfree;
    mainProgram = "anisette-v3-server";
    platforms = [ "aarch64-linux" "x86_64-linux" ];
  };
}
