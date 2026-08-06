# RTK — Rust Token Killer (rtk-ai/rtk). A CLI proxy that rewrites verbose dev
# commands (`git status` → `rtk git status`, …) so an LLM sees 60–90% fewer
# tokens of command output.
#
# Built from source via the `rtk-src` flake input (flake.nix, `flake = false`),
# NOT a prebuilt release binary — keeps the build in-tree and reproducible like
# the repo's other source inputs (picoclaw-src, cyrus-src, gogcli-src).
#
# Build notes (verified against v0.42.4):
#   - Pure-Rust crates.io deps; Cargo.lock has no git sources, so
#     `cargoLock.lockFile` alone suffices (no outputHashes/vendorHash).
#   - `rusqlite { features = ["bundled"] }` compiles SQLite's C via the `cc`
#     crate — stdenv's compiler covers it; no system sqlite, no bindgen/libclang.
#   - `ureq` uses rustls → no OpenSSL.
#   - rtk's release profile is `lto = true, codegen-units = 1` → a heavy compile.
#     On the rpi5 build with `--max-jobs 1 -j1` (won't hit a binary cache).
{
  lib,
  rustPlatform,
  rtk-src,
}:
rustPlatform.buildRustPackage {
  pname = "rtk";
  version = "0.42.4"; # keep in sync with the rtk-src tag in flake.nix

  src = rtk-src;

  cargoLock.lockFile = "${rtk-src}/Cargo.lock";

  # Upstream's tests carry fixtures and shell out to real dev tools (git, cargo,
  # …) not present in the Nix sandbox; smoke-test the built binary instead.
  doCheck = false;

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/rtk --version
    runHook postInstallCheck
  '';

  meta = {
    description = "Rust Token Killer — CLI proxy that compresses dev-command output for LLMs";
    homepage = "https://github.com/rtk-ai/rtk";
    license = lib.licenses.asl20;
    mainProgram = "rtk";
    platforms = lib.platforms.unix;
  };
}
