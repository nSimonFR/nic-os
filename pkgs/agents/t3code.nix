# t3 — the T3 Code CLI and headless server (pingdotgg/t3code), from the
# release archive that upstream's install.sh unpacks into ~/.t3/runtime.
#
# `t3` is a Node single-executable app: the JS bundle rides in an ELF note, so
# patchelf is safe (verified on 0.0.45) but strip is not.
#
# linux-arm64 runs the rpi5 server; darwin-arm64 only gives the Mac a CLI
# (linear-t3-relay mints pairing codes with it), the Mac's server is the desktop
# app. Bumps come from Renovate; `t3 update` must not be used, it installs a
# second copy under ~/.t3/runtime.
#
# Tracks the stable channel, like ./t3code-desktop.nix: the server and the Mac
# app must run the same version or the app loses its sessions over T3 Connect.
#
# linux-arm64 comes from the nSimonFR-ai/t3code `-issues.N` release instead: the
# same release plus the fork's small changes (its spec.md: no notification sound
# while the screen is locked, Claude artifact watchers). The fork carried the
# Issues stack up to 0.1.10; upstream ships Issues since 0.1.11. A database
# written by those builds needs ~/.t3/backups/t3-fork-exit.sql before its first
# start on 0.1.11. .github/workflows/t3code-fork-release.yml builds the release
# and pins the hashes on the bump PR.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  vulkan-loader,
}:
let
  # renovate: datasource=github-releases depName=pingdotgg/t3code extractVersion=^v(?<version>.+)$
  version = "0.1.11";
  platform = if stdenv.hostPlatform.isDarwin then "darwin-arm64" else "linux-arm64";
  sources = {
    linux-arm64 = {
      url = "https://github.com/nSimonFR-ai/t3code/releases/download/v${version}-issues.1/t3-${version}-issues-linux-arm64.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    darwin-arm64 = {
      url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/t3-${version}-darwin-arm64.tar.gz";
      hash = "sha256-S8IuFqLkjYaK2MS51sjgMb4cVmzjHCgmeVXCmGpw6V8=";
    };
  };
in
stdenv.mkDerivation {
  pname = "t3code";
  inherit version;

  src = fetchurl {
    name = "t3-${version}-${platform}.tar.gz";
    inherit (sources.${platform}) url hash;
  };

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  # libstdc++ and libatomic, for t3 itself and node-pty's pty.node; libvulkan for
  # the transcribe-cpp ggml-vulkan backend.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
    vulkan-loader
  ];

  dontStrip = true;

  # The binary resolves node_modules/, client/ and resource-monitor/ beside its
  # real path, so the tree stays whole under libexec.
  installPhase = ''
    runHook preInstall

    # Alpine variant of a lib the gnu one already covers; it would fail autoPatchelf.
    rm -rf node_modules/@ff-labs/fff-bin-linux-arm64-musl node_modules/@koromix/koffi-linux-arm64/musl_arm64

    mkdir -p $out/libexec $out/bin
    cp -r . $out/libexec/t3code
    ln -s $out/libexec/t3code/t3 $out/bin/t3

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/t3 --version | grep -qF '${version}'
    runHook postInstallCheck
  '';

  meta = {
    description = "T3 Code CLI and headless server";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    mainProgram = "t3";
    platforms = [
      "aarch64-linux"
      "aarch64-darwin"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
