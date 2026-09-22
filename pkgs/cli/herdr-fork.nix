# herdr, jerryfane's fork — the build the HerdrUp phone app pairs with
# (`herdr pair`, plus the `api-bridge` entrypoint it runs over SSH). Upstream
# herdr has neither.
#
# Only prebuilt preview binaries are published (static on Linux), so this
# repackages the release asset. Hashes are the manifest's sha256, SRI-encoded:
# https://raw.githubusercontent.com/jerryfane/herdr/master/distribution/preview.json
#
# `herdr update` can't write the store; bump `buildId`/`commit`/hashes here.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  buildId = "2026-09-20-d79b0216a175";
  commit = "d79b0216a175d4707c8b3a18cbf50f362dcc2325";

  assets = {
    x86_64-linux = {
      target = "linux-x86_64";
      hash = "sha256-jnvkknHYxZmuAOLW+G2hp5TsZLX5CEXWhP9xG+Sh+EI=";
    };
    aarch64-linux = {
      target = "linux-aarch64";
      hash = "sha256-BxhsnbwecTUCBnv2uoMc7yNhVlCsbUvNwkrJtlJazHQ=";
    };
    x86_64-darwin = {
      target = "macos-x86_64";
      hash = "sha256-HSN1y8DcHlDyCBfDNZ/Ew+1RY2gK2DaxzlAzoDl3OJw=";
    };
    aarch64-darwin = {
      target = "macos-aarch64";
      hash = "sha256-c2gLbaTpNyZuIetYWt0Mk6UVBzvI6ZtO5YDmI88VeGs=";
    };
  };
  asset =
    assets.${stdenvNoCC.hostPlatform.system}
      or (throw "herdr-fork: no prebuilt binary for ${stdenvNoCC.hostPlatform.system}");

  # Same share/skills/herdr layout as nixpkgs' herdr, so home/claude.nix can
  # take the version-matched skill from either.
  skill = fetchurl {
    url = "https://raw.githubusercontent.com/jerryfane/herdr/${commit}/skills/herdr/SKILL.md";
    hash = "sha256-0UNlKbr6NCgXALSFEiTAumOy8WU8yiugt5HB0oLQ6Q4=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "herdr-fork-${buildId}";
  version = "0.9.1";

  src = fetchurl {
    name = "herdr-${asset.target}-${buildId}";
    url = "https://github.com/jerryfane/herdr/releases/download/preview-${buildId}/herdr-${asset.target}";
    inherit (asset) hash;
  };

  dontUnpack = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/herdr
    install -Dm644 ${skill} $out/share/skills/herdr/SKILL.md
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/herdr --version | grep -q '${builtins.substring 0 7 commit}'
  '';

  meta = {
    description = "herdr fork with HerdrUp phone pairing and saved-machine federation";
    homepage = "https://github.com/jerryfane/herdr";
    license = lib.licenses.asl20;
    mainProgram = "herdr";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
