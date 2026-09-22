# zoetrope (furkankly/zoetrope) — `zoe`, a terminal UI that renders a Claude Code
# or Codex session as a live flow graph, with the session's SUBAGENTS nested
# under the main agent. Read-only, no network.
#
# Not in nixpkgs and upstream ships no flake, so it is built here. Single
# consumer (home/herdr.nix), so it is not in pkgs/overlay.nix.
#
# Crate is `zoetrope`, binary is `zoe`. No git sources in Cargo.lock, so
# `cargoLock.lockFile` alone; no OpenSSL, bindgen or system libs.
{
  lib,
  rustPlatform,
  zoetrope-src,
}:
rustPlatform.buildRustPackage {
  pname = "zoetrope";
  version = "0.2.0"; # keep in sync with the zoetrope-src tag in flake.nix

  src = zoetrope-src;

  cargoLock.lockFile = "${zoetrope-src}/Cargo.lock";

  # Upstream's suite renders frames against fixture transcripts; the binary is
  # what this package promises, so smoke-test that instead.
  doCheck = false;

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/zoe --version
    runHook postInstallCheck
  '';

  meta = {
    description = "Terminal UI that visualizes Claude Code and Codex agent sessions as a live flow graph";
    homepage = "https://github.com/furkankly/zoetrope";
    license = lib.licenses.mit;
    mainProgram = "zoe";
    platforms = lib.platforms.unix;
  };
}
