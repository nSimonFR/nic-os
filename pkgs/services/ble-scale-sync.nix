# ble-scale-sync (KristianP26) — Node BLE bridge for Qingniu "QN-Scale" devices.
# Connects over BlueZ, decodes weight + impedance, computes body-composition
# metrics from a user profile and POSTs them to a webhook.
#
# Service module (user, unit, secrets, webhook target): hosts/rpi5/scale-bridge.nix.
{
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  nodejs_22,
  pkg-config,
  python3,
  systemdLibs,
}:

buildNpmPackage rec {
  pname = "ble-scale-sync";
  # Deliberately NOT given a `# renovate:` comment (see renovate.json): `rev` is
  # a bare commit, so `version` is only a label and bumping it would move
  # nothing. Upstream is at v1.22.1; picking it up means changing `rev` too.
  version = "1.21.0";
  src = fetchFromGitHub {
    # Version in the name so a stale `hash` fails loudly — see pkgs/README.md.
    name = "${pname}-${version}-source";
    owner = "KristianP26";
    repo = "ble-scale-sync";
    rev = "2965b2ed09fdb0b53244bd731cbb37a52637343f";
    hash = "sha256-eziNlpDcs3w17ca8pokabrzLo8AFTH+spOreiyYSPqQ=";
  };
  npmDepsHash = "sha256-MRXV0tsZq9zf7iH2RXbQ1+LySO98l6uQBgyAcaHa2uY=";
  nodejs = nodejs_22;
  # @abandonware/noble + bluetooth-hci-socket native addons need node-gyp
  # (python) and libudev.
  nativeBuildInputs = [ python3 pkg-config makeWrapper ];
  buildInputs = [ systemdLibs ];
  # The app runs straight from TypeScript source via tsx (main = src/index.ts);
  # there is no compiled dist, so skip the `tsc` build.
  dontNpmBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/ble-scale-sync $out/bin
    cp -r . $out/lib/ble-scale-sync/
    makeWrapper ${nodejs_22}/bin/node $out/bin/ble-scale-sync \
      --add-flags "$out/lib/ble-scale-sync/node_modules/tsx/dist/cli.mjs" \
      --add-flags "$out/lib/ble-scale-sync/src/index.ts" \
      --chdir "$out/lib/ble-scale-sync"
    runHook postInstall
  '';
  meta.mainProgram = "ble-scale-sync";
}
