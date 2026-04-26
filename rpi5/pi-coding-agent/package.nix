{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  glibc,
  version ? "0.70.2",
}:

# Pi Coding Agent (Mario Zechner / badlogic/pi-mono).
#
# Distributed as a Bun-compiled single-file binary. We fetch the upstream
# release tarball directly — no `buildNpmPackage`, so bumps are just
# version + sha256 swaps.
#
# IMPORTANT: Bun --compile binaries embed the entry script in a trailer at
# the END of the ELF file. `patchelf --set-rpath` (which autoPatchelfHook
# applies) shifts/rewrites the file and corrupts that trailer — the binary
# then falls back to plain-Bun mode and prints the Bun help. Same gotcha
# the user hit with tailwindcss-ruby (see sure-nix memory). Workaround:
# only `patchelf --set-interpreter` (safe), and wrap with LD_LIBRARY_PATH
# instead of letting autoPatchelfHook touch the rpath.

stdenv.mkDerivation {
  pname = "pi-coding-agent";
  inherit version;

  src = fetchurl {
    url = "https://github.com/badlogic/pi-mono/releases/download/v${version}/pi-linux-arm64.tar.gz";
    sha256 = "1vz6j1dwspc6n0a21v4syx2x76gnmhqhf6n2lx9mcwxza1805xci";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;
  dontPatchELF = true;

  unpackPhase = ''
    runHook preUnpack
    tar -xzf $src
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    # Tarball lays out as pi/{pi,README.md,examples/,assets/,theme/,...}.
    # Pi loads sibling files (theme/, photon_rs_bg.wasm, export-html/) by
    # path relative to the binary, so we install the whole directory.
    mkdir -p $out/share/pi-coding-agent $out/bin
    cp -r pi/* $out/share/pi-coding-agent/

    # Set the dynamic linker only — DO NOT --set-rpath (corrupts the Bun
    # trailer, sends the binary into plain-Bun fallback mode).
    patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" \
      $out/share/pi-coding-agent/pi

    # Wrapper supplies the runtime libraries Bun needs without touching
    # the binary's own rpath.
    makeWrapper $out/share/pi-coding-agent/pi $out/bin/pi \
      --prefix LD_LIBRARY_PATH : "${
        lib.makeLibraryPath [ stdenv.cc.cc.lib glibc ]
      }"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Minimal AI coding agent (Bun-compiled)";
    homepage = "https://github.com/badlogic/pi-mono";
    license = licenses.mit;
    mainProgram = "pi";
    platforms = [ "aarch64-linux" ];
  };
}
