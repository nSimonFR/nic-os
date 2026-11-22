{
  lib,
  stdenvNoCC,
  fetchurl,
}:
# shellwatch-agent — local SSH-agent socket that relays sign requests to a
# ShellWatch server, which asks the passkey on the phone. Static Go binary.
let
  # renovate: datasource=github-releases depName=rado0x54/ShellWatch extractVersion=^agent/v(?<version>.+)$
  version = "1.2.0";
  assets = {
    aarch64-linux = {
      asset = "linux-arm64";
      hash = "sha256-SxLxCaLaMquvsPobXy9ynO3q38U2t+5nOQIRMaK7epA=";
    };
    x86_64-linux = {
      asset = "linux-amd64";
      hash = "sha256-gMSoYbFG5P2BtQHQbcjhZxrM1BcvTqz5FxBPHKlvMkA=";
    };
  };
  inherit (stdenvNoCC.hostPlatform) system;
  target = assets.${system} or (throw "shellwatch-agent: no release asset for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "shellwatch-agent";
  inherit version;

  src = fetchurl {
    name = "shellwatch-agent-${version}-${target.asset}";
    url = "https://github.com/rado0x54/ShellWatch/releases/download/agent/v${version}/shellwatch-agent-${target.asset}";
    inherit (target) hash;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  installPhase = "install -Dm755 $src $out/bin/shellwatch-agent";

  meta = {
    description = "SSH agent proxy for ShellWatch passkeys";
    homepage = "https://github.com/rado0x54/ShellWatch";
    license = lib.licenses.unfreeRedistributable; # FSL-1.1-Apache-2.0
    mainProgram = "shellwatch-agent";
    platforms = lib.attrNames assets;
  };
}
