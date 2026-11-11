# A mautrix bridge from upstream's own release binary (static, aarch64): the ones
# nixpkgs lacks (Telegram's Go rewrite, LinkedIn, X) or ships only linked against
# the insecure-flagged libolm (Discord). Same recipe as mtg-mcp: no Go toolchain,
# no vendorHash; a bump is the tag plus the hash from the release's sha256sums.txt.
{
  lib,
  stdenvNoCC,
  fetchurl,
  repo,
  tag,
  hash,
}:
stdenvNoCC.mkDerivation {
  pname = "mautrix-${repo}";
  version = lib.removePrefix "v" tag;

  src = fetchurl {
    url = "https://github.com/mautrix/${repo}/releases/download/${tag}/mautrix-${repo}-arm64";
    inherit hash;
  };
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
