{
  lib,
  stdenvNoCC,
  fetchurl,
}:
# mtg-mcp — native MCP server exposing Magic: The Gathering / Commander tools
# (Scryfall card search + pricing + rulings + legality, deck validation,
# Moxfield/Archidekt deck import, EDHREC recs/combos, comprehensive rules).
# All public data — no auth or API keys.
#
# Upstream ships static (CGO-free) Go release binaries, so we fetch+install them
# directly rather than buildGoModule (no vendorHash, no Go toolchain at build
# time). Extracted out of rpi5/hermes/hermes.nix when the Mac's `claude-mtg` CLI
# (home/claude-mtg.nix) started needing the same server — hence the per-platform
# asset table below, where the Hermes-only version hardcoded Linux/arm64.
#
# Bumping: change `version`, then refresh every hash with
#   nix store prefetch-file https://github.com/nathanmartins/mtg-mcp/releases/download/v<ver>/mtg-mcp_<asset>.tar.gz
let
  version = "2.1.0";

  # asset name (upstream release file) + sha256 of the .tar.gz, per Nix system.
  assets = {
    "aarch64-darwin" = {
      asset = "Darwin_arm64";
      hash = "sha256-IdcMsmH4oFvXdcBkIpA/C80rgROx18TRizfpwXj4lio=";
    };
    "x86_64-darwin" = {
      asset = "Darwin_x86_64";
      hash = "sha256-8xTK20TSN2mTMzEUOkQ+fCmDcJo7hNUk/kMd77KUcB8=";
    };
    "aarch64-linux" = {
      asset = "Linux_arm64";
      hash = "sha256-NajD9ADrQoVOtQiL+X0tVjA7wR5ZI+yIZQvRQM+JHN4=";
    };
    "x86_64-linux" = {
      asset = "Linux_x86_64";
      hash = "sha256-kZgBskCfW31WSqkK+vkFfu+Scs99cqZTmu7SIPmOX5E=";
    };
  };

  inherit (stdenvNoCC.hostPlatform) system;
  selected =
    assets.${system}
      or (throw "mtg-mcp: no upstream release asset for system ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "mtg-mcp";
  inherit version;

  src = fetchurl {
    url = "https://github.com/nathanmartins/mtg-mcp/releases/download/v${version}/mtg-mcp_${selected.asset}.tar.gz";
    inherit (selected) hash;
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 mtg-mcp $out/bin/mtg-mcp
    runHook postInstall
  '';

  meta = {
    description = "MCP server for Magic: The Gathering Commander (Scryfall, decks, rules)";
    homepage = "https://github.com/nathanmartins/mtg-mcp";
    license = lib.licenses.mit;
    mainProgram = "mtg-mcp";
    platforms = lib.attrNames assets;
  };
}
