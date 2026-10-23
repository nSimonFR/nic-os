{ lib, stdenvNoCC, fetchurl }:
# Agent Vault (Infisical) — credential-brokering MITM proxy for AI agents.
# Upstream's release binaries embed the web UI (a source build would need the
# npm frontend plus go >= 1.26.10; nixpkgs has 1.26.4).
#
# Bump `version`, then refresh each hash with:
#   nix store prefetch-file https://github.com/Infisical/agent-vault/releases/download/v<ver>/agent-vault_<ver>_<asset>.tar.gz
let
  version = "0.40.2";
  assets = {
    aarch64-linux = { asset = "linux_arm64"; hash = "sha256-21CkaN+DP4rjWEEuN5DIPhpondBycsdvY0r7JY2fWCc="; };
    x86_64-linux  = { asset = "linux_amd64"; hash = "sha256-bYoS9AVeWwJE95wMaqVBXCmIuR9bFqLAuStYl7i652s="; };
  };
  inherit (stdenvNoCC.hostPlatform) system;
  target = assets.${system} or (throw "agent-vault: no release asset for ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "agent-vault";
  inherit version;

  src = fetchurl {
    url = "https://github.com/Infisical/agent-vault/releases/download/v${version}/agent-vault_${version}_${target.asset}.tar.gz";
    inherit (target) hash;
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  installPhase = "install -Dm755 agent-vault $out/bin/agent-vault";

  meta = {
    description = "HTTP credential proxy and vault for AI agents";
    homepage = "https://github.com/Infisical/agent-vault";
    license = lib.licenses.mit;
    mainProgram = "agent-vault";
    platforms = lib.attrNames assets;
  };
}
