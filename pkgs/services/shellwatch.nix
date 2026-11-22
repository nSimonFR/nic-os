{
  lib,
  stdenvNoCC,
  fetchurl,
}:
# ShellWatch server — passkey-gated SSH approvals, Web Push, MCP.
# Upstream's static release binary embeds the SvelteKit UI (a source build needs
# the pnpm frontend plus Go 1.27).
let
  # renovate: datasource=github-releases depName=rado0x54/ShellWatch extractVersion=^v(?<version>.+)$
  version = "2.2.0";
  assets = {
    aarch64-linux = {
      asset = "linux-arm64";
      hash = "sha256-rk38XoGZ3+D5uc+Hn7HIgatNCPbyJDpzB9Fz+Ch8WzU=";
    };
    x86_64-linux = {
      asset = "linux-amd64";
      hash = "sha256-ypEZayxwx3f0Z3ryeUK85XK+eqoZtrF75t2aN/9q+Yc=";
    };
  };
  inherit (stdenvNoCC.hostPlatform) system;
  target = assets.${system} or (throw "shellwatch: no release asset for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "shellwatch";
  inherit version;

  src = fetchurl {
    name = "shellwatch-${version}-${target.asset}.tar.gz";
    url = "https://github.com/rado0x54/ShellWatch/releases/download/v${version}/shellwatch-${version}-${target.asset}.tar.gz";
    inherit (target) hash;
  };

  dontConfigure = true;
  dontBuild = true;
  installPhase = "install -Dm755 shellwatch $out/bin/shellwatch";

  meta = {
    description = "Passkey-backed SSH for humans and agents";
    homepage = "https://github.com/rado0x54/ShellWatch";
    license = lib.licenses.unfreeRedistributable; # FSL-1.1-Apache-2.0
    mainProgram = "shellwatch";
    platforms = lib.attrNames assets;
  };
}
