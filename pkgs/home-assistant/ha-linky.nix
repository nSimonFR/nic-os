# bokub/ha-linky — TypeScript/Node.js Linky → Home Assistant bridge.
#
# config.ts hardcodes /data/options.json and ha.ts reads WS_URL +
# SUPERVISOR_TOKEN from the environment; the unit supplies both.
#
# Service module (unit, /data bind mount, EnvironmentFile): hosts/rpi5/home-assistant/default.nix.
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
  version = "1.9.0";
  src = fetchFromGitHub {
    # Version in the name so a stale `hash` fails loudly.
    # See "Fixed-output names" in pkgs/README.md.
    name = "${pname}-${version}-source";
    owner = "bokub";
    repo = "ha-linky";
    rev = version;
    hash = "sha256-i6RqhzlzUXWZ2kbVEgNf6KbxwyLQHC4qIP4PQo8RH1A=";
  };
  npmDepsHash = "sha256-ErFaImwJUCVJv2fIf/aUkIDpwy40UcOuGVNh80nrlaU=";
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
