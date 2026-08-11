{ lib, stdenvNoCC, fetchurl }:
# mtg-mcp — MCP server for Magic: The Gathering / Commander (Scryfall search,
# pricing, rulings, legality, deck validation, Moxfield/Archidekt import, EDHREC).
# All public data, no auth. Upstream ships static Go binaries, so we install those
# rather than buildGoModule (no vendorHash, no Go toolchain).
#
# Used by both hosts/rpi5/hermes/hermes.nix and home/claude-mtg.nix — hence the
# per-platform table. Bump: change `version`, then refresh each hash with
#   nix store prefetch-file https://github.com/nathanmartins/mtg-mcp/releases/download/v<ver>/mtg-mcp_<asset>.tar.gz
#
# Deliberately NOT given a `# renovate:` comment (see renovate.json): four
# per-platform hashes to refresh by hand makes a version-only bump PR more
# misleading than useful. This recipe is the supported path.
let
  version = "2.1.0";
  assets = {
    aarch64-darwin = { asset = "Darwin_arm64";  hash = "sha256-IdcMsmH4oFvXdcBkIpA/C80rgROx18TRizfpwXj4lio="; };
    x86_64-darwin  = { asset = "Darwin_x86_64"; hash = "sha256-8xTK20TSN2mTMzEUOkQ+fCmDcJo7hNUk/kMd77KUcB8="; };
    aarch64-linux  = { asset = "Linux_arm64";   hash = "sha256-NajD9ADrQoVOtQiL+X0tVjA7wR5ZI+yIZQvRQM+JHN4="; };
    x86_64-linux   = { asset = "Linux_x86_64";  hash = "sha256-kZgBskCfW31WSqkK+vkFfu+Scs99cqZTmu7SIPmOX5E="; };
  };
  inherit (stdenvNoCC.hostPlatform) system;
  target = assets.${system} or (throw "mtg-mcp: no release asset for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "mtg-mcp";
  inherit version;

  src = fetchurl {
    url = "https://github.com/nathanmartins/mtg-mcp/releases/download/v${version}/mtg-mcp_${target.asset}.tar.gz";
    inherit (target) hash;
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  installPhase = "install -Dm755 mtg-mcp $out/bin/mtg-mcp";

  meta = {
    description = "MCP server for Magic: The Gathering Commander (Scryfall, decks, rules)";
    homepage = "https://github.com/nathanmartins/mtg-mcp";
    license = lib.licenses.mit;
    mainProgram = "mtg-mcp";
    platforms = lib.attrNames assets;
  };
}
