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
# Tracks the nightly channel, matching the Mac's "T3 Code (Nightly)" app: a
# stable server behind a nightly client loses access to its sessions.
#
# linux-arm64 comes from the nSimonFR-ai/t3code `-issues.N` release instead:
# the same nightly plus pingdotgg/t3code#6315 (Issues page, Linear trees) and
# #15827 + #17432 (mod UI), matching ./t3code-desktop.nix. A bump needs that
# release rebuilt first; see its notes.
{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:
let
  # renovate: datasource=github-releases depName=pingdotgg/t3code extractVersion=^v(?<version>.+)$
  version = "0.0.46-nightly.20261009.2861";
  platform = if stdenv.hostPlatform.isDarwin then "darwin-arm64" else "linux-arm64";
  sources = {
    linux-arm64 = {
      url = "https://github.com/nSimonFR-ai/t3code/releases/download/v${version}-issues.1/t3-${version}-issues-linux-arm64.tar.gz";
      hash = "sha256-YYjfb8l6lJ8Vlm6quE7KHSsKGiDg+DAmfyqw74WpNL8=";
    };
    darwin-arm64 = {
      url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/t3-${version}-darwin-arm64.tar.gz";
      hash = "sha256-RD4LwkQCEyeDRidsVxX8bRRX7oEaOSFW1Gg04g1ah4o=";
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
  # libstdc++ and libatomic, for t3 itself and node-pty's pty.node.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  dontStrip = true;

  # The binary resolves node_modules/, client/ and resource-monitor/ beside its
  # real path, so the tree stays whole under libexec.
  installPhase = ''
    runHook preInstall

    # Alpine variant of a lib the gnu one already covers; it would fail autoPatchelf.
    rm -rf node_modules/@ff-labs/fff-bin-linux-arm64-musl

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
    platforms = [ "aarch64-linux" "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
