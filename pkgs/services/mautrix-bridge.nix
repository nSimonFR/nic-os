# A mautrix bridge from upstream's own release binary (static, aarch64): the ones
# nixpkgs lacks (Telegram's Go rewrite, LinkedIn, X) or ships only linked against
# the insecure-flagged libolm (Discord). Same recipe as mtg-mcp: no Go toolchain,
# no vendorHash. The caller pins `src` (hosts/rpi5/messaging/bridges.nix, Renovate-tracked).
{
  lib,
  stdenvNoCC,
  repo,
  version,
  src,
}:
stdenvNoCC.mkDerivation {
  pname = "mautrix-${repo}";
  inherit version src;
  dontUnpack = true;
  installPhase = "install -Dm755 $src $out/bin/mautrix-${repo}";

  meta = {
    description = "Matrix-${repo} puppeting bridge (upstream release binary)";
    homepage = "https://github.com/mautrix/${repo}";
    license = lib.licenses.agpl3Only;
    platforms = [ "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "mautrix-${repo}";
  };
}
