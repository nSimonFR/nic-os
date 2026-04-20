{
  lib,
  buildGoModule,
  picoclaw-src,
  version ? "0.2.6",
  vendorHash ? "sha256-ARQUWPdeF+y74cWW7UHggdJ+VhrKjkQmGLtBXITsMOE=",
}:

# PicoClaw: ultra-lightweight Go-based AI agent.
#
# Source is taken from the `picoclaw-src` flake input (pinned to a tag in
# flake.nix). Upgrading requires bumping the tag there AND `version` here;
# the commit rev + narHash come from flake.lock automatically.
#
# Upstream go.mod requires Go ≥1.25.9; nixpkgs 25.11 ships 1.25.8. Callers
# must pass buildGoModule from nixpkgs-unstable (Go 1.26.x) via the
# unstablePkgs overlay.
buildGoModule {
  pname = "picoclaw";
  inherit version vendorHash;

  src = picoclaw-src;

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
    "-X github.com/sipeed/picoclaw/pkg/config.GitCommit=${picoclaw-src.shortRev or "dirty"}"
    "-X github.com/sipeed/picoclaw/pkg/config.GoVersion=nix"
  ];

  # The onboard command uses //go:embed workspace, populated by //go:generate.
  # Nix doesn't run go generate, so copy the workspace dir into position.
  preBuild = ''
    cp -r workspace cmd/picoclaw/internal/onboard/workspace
  '';

  # No CGO: keeps the binary static and small (the ~10MB claim relies on this).
  env.CGO_ENABLED = "0";

  doCheck = false;

  meta = with lib; {
    description = "Tiny Go-based personal AI agent (OpenClaw alternative)";
    homepage = "https://github.com/sipeed/picoclaw";
    license = licenses.mit;
    mainProgram = "picoclaw";
    platforms = platforms.unix;
  };
}
