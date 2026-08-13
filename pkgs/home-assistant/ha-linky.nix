# bokub/ha-linky — TypeScript/Node.js Linky → Home Assistant bridge.
#
# config.ts hardcodes /data/options.json and ha.ts reads WS_URL +
# SUPERVISOR_TOKEN from the environment; the unit supplies both.
#
# Service module (unit, /data bind mount, EnvironmentFile): hosts/rpi5/home-assistant.nix.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  nodejs,
}:

buildNpmPackage rec {
  pname = "ha-linky";
  # renovate: datasource=github-releases depName=bokub/ha-linky
  version = "1.7.0";
  src = fetchFromGitHub {
    # Version in the name so a stale `hash` fails loudly.
    # See .cursor/rules/fixed-output-names.mdc.
    name = "${pname}-${version}-source";
    owner = "bokub";
    repo = "ha-linky";
    rev = version;
    hash = "sha256-x8W/kR/L3uJ317MAayv3mUlPW3yw+Tnj4iD2c6CEnOQ=";
  };
  npmDepsHash = "sha256-y/64htlLa5RGemCIqXp9nxDgAK8zyVOq8kdW4azhY64=";
  # npm run build = tsc → dist/
  # Skip the default `npm install -g` install phase; we install manually.
  dontNpmInstall = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/{bin,lib/ha-linky}
    # node_modules must live next to dist/ for ESM relative-path resolution
    cp -r dist node_modules $out/lib/ha-linky/
    makeWrapper ${lib.getExe nodejs} $out/bin/ha-linky \
      --add-flags "$out/lib/ha-linky/dist/index.js"
    runHook postInstall
  '';
}
