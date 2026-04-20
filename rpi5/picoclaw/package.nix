{
  lib,
  buildGoModule,
  fetchFromGitHub,
  version ? "0.2.6",
  rev ? "d946d8f7610b1b2b87afd1e16d442b1c271cb1eb",
  hash ? "", # fill via first build; TOFU
  vendorHash ? null, # fill via first build
}:

# PicoClaw: ultra-lightweight Go-based AI agent.
#
# Upstream go.mod requires Go 1.25.9; nixpkgs 25.11 ships 1.25.8. The patch-level
# mismatch is usually benign at build time; if Go rejects the toolchain, bump the
# nixpkgs pin or set GOTOOLCHAIN=local via env.
buildGoModule {
  pname = "picoclaw";
  inherit version vendorHash;

  src = fetchFromGitHub {
    owner = "sipeed";
    repo = "picoclaw";
    inherit rev hash;
  };

  # Upstream Makefile build tags; `goolm` selects the Go-native OLM crypto,
  # `stdjson` uses encoding/json instead of any faster third-party lib.
  tags = [ "goolm" "stdjson" ];

  # Build only the main binary; the tui and membench commands are optional.
  subPackages = [ "cmd/picoclaw" ];

  # Stamp version info into the binary the same way `make` does, so
  # `picoclaw --version` is accurate.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/sipeed/picoclaw/pkg/config.Version=${version}"
    "-X github.com/sipeed/picoclaw/pkg/config.GitCommit=${builtins.substring 0 8 rev}"
    "-X github.com/sipeed/picoclaw/pkg/config.GoVersion=nix"
  ];

  # No CGO: keeps the binary static and small (the ~10MB claim relies on this).
  env.CGO_ENABLED = "0";

  # Required so Go doesn't reject 1.25.8 when go.mod says 1.25.9.
  env.GOTOOLCHAIN = "local";

  doCheck = false;

  meta = with lib; {
    description = "Tiny Go-based personal AI agent (OpenClaw alternative)";
    homepage = "https://github.com/sipeed/picoclaw";
    license = licenses.mit;
    mainProgram = "picoclaw";
    platforms = platforms.unix;
  };
}
