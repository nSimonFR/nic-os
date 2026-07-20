# rpi5/scale-bridge.nix
#
# Loftilla CS20B (a Qingniu "QN-Scale", MAC 24:62:AB:C6:9B:16) → Ryot bridge.
#
# Two native systemd services:
#   * ble-scale-sync.service — third-party Node BLE bridge (KristianP26/ble-scale-sync),
#     packaged from source below. Connects to the QN scale over BlueZ (onboard
#     hci0), decodes weight + impedance, computes 10 body-composition metrics
#     from the user profile, and POSTs them as JSON to the local shim's webhook.
#     Runs as root: node-ble talks to org.bluez over the system D-Bus, which the
#     default BlueZ policy only grants root/at_console (same rationale as the
#     other root-run local daemons here, e.g. travel-cal-sync).
#   * scale-to-ryot.service — tiny stdlib-Python shim (scripts/scale-to-ryot.py)
#     that translates that webhook into a Ryot `createOrUpdateUserMeasurement`
#     GraphQL mutation against the backend on 127.0.0.1:13352. Runs as the
#     unprivileged `scale-bridge` user.
#
# Bluetooth: the onboard radio is force-enabled in configuration.nix (the
# raspberry-pi-5.bluetooth module + the mkForce toggle there). This module only
# sets powerOnBoot so hci0 comes up ready to scan.
#
# Secrets (agenix `scale-bridge-env`, KEY=VALUE, owner scale-bridge 0400 — root
# reads it too): RYOT_TOKEN (shim → Ryot, per-user API token), SHIM_KEY (shared
# webhook secret), and the body-composition profile USER_HEIGHT / USER_BIRTH_DATE
# / USER_GENDER. The profile is PII and this repo is public, so config.yaml is
# rendered at activation from that secret into /etc (never the Nix store / git).
{ config, pkgs, lib, ... }:
let
  shimPort = 8349; # scale-to-ryot shim, 127.0.0.1 only (8347 taken by papra-webhook)
  scaleMac = "24:62:AB:C6:9B:16"; # the QN-Scale (local BT address, not sensitive)
  ryotUrl = "http://127.0.0.1:13352/graphql"; # ryot-backend (see ryot.nix)

  bleScaleSync = pkgs.buildNpmPackage rec {
    pname = "ble-scale-sync";
    version = "1.21.0";
    src = pkgs.fetchFromGitHub {
      owner = "KristianP26";
      repo = "ble-scale-sync";
      rev = "2965b2ed09fdb0b53244bd731cbb37a52637343f";
      hash = "sha256-eziNlpDcs3w17ca8pokabrzLo8AFTH+spOreiyYSPqQ=";
    };
    npmDepsHash = "sha256-MRXV0tsZq9zf7iH2RXbQ1+LySO98l6uQBgyAcaHa2uY=";
    nodejs = pkgs.nodejs_22;
    # @abandonware/noble + bluetooth-hci-socket native addons need node-gyp
    # (python) and libudev.
    nativeBuildInputs = [ pkgs.python3 pkgs.pkg-config pkgs.makeWrapper ];
    buildInputs = [ pkgs.systemdLibs ];
    # The app runs straight from TypeScript source via tsx (main = src/index.ts);
    # there is no compiled dist, so skip the `tsc` build.
    dontNpmBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/ble-scale-sync $out/bin
      cp -r . $out/lib/ble-scale-sync/
      makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/ble-scale-sync \
        --add-flags "$out/lib/ble-scale-sync/node_modules/tsx/dist/cli.mjs" \
        --add-flags "$out/lib/ble-scale-sync/src/index.ts" \
        --chdir "$out/lib/ble-scale-sync"
      runHook postInstall
    '';
    meta.mainProgram = "ble-scale-sync";
  };
in
{
  # hci0 up at boot (enable itself is toggled in configuration.nix).
  hardware.bluetooth.powerOnBoot = true;

  # Unprivileged user for the shim (reads the agenix secret; root reads it too).
  users.users.scale-bridge = {
    isSystemUser = true;
    group = "scale-bridge";
  };
  users.groups.scale-bridge = { };

  # ── Shim: webhook → Ryot GraphQL ──────────────────────────────────────────
  systemd.services.scale-to-ryot = {
    description = "scale-to-ryot: webhook → Ryot measurement shim";
    wantedBy = [ "multi-user.target" ];
    after = [ "ryot-backend.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.python3 ];
    environment = {
      SHIM_PORT = toString shimPort;
      RYOT_URL = ryotUrl;
      MEASUREMENT_NAME = "Loftilla";
    };
    serviceConfig = {
      Type = "simple";
      User = "scale-bridge";
      Group = "scale-bridge";
      # SHIM_KEY + RYOT_TOKEN come from the agenix secret.
      EnvironmentFile = "/run/agenix/scale-bridge-env";
      # Wait for the Ryot backend to actually answer before serving.
      ExecStartPre = pkgs.writeShellScript "wait-for-ryot" ''
        for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
          if ${pkgs.curl}/bin/curl -fsS --connect-timeout 2 -o /dev/null \
              -X POST -H 'Content-Type: application/json' \
              --data '{"query":"{__typename}"}' ${ryotUrl}; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 2
        done
        echo "scale-to-ryot: timed out waiting for Ryot backend" >&2
        exit 1
      '';
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/scale-to-ryot.py}";
      Restart = "on-failure";
      RestartSec = "15";
    };
  };

  # ── ble-scale-sync: BLE → webhook ─────────────────────────────────────────
  systemd.services.ble-scale-sync = {
    description = "ble-scale-sync: Loftilla/QN scale → shim";
    wantedBy = [ "multi-user.target" ];
    # localhost shim + local BlueZ only — no network-online dependency needed.
    after = [ "bluetooth.service" "scale-to-ryot.service" ];
    wants = [ "bluetooth.service" "scale-to-ryot.service" ];
    environment = {
      CONTINUOUS_MODE = "true";
      # config.yaml is rendered at activation into /etc (holds the PII profile).
    };
    serviceConfig = {
      Type = "simple";
      User = "root"; # node-ble needs org.bluez system-D-Bus access
      # SHIM_KEY is baked into config.yaml at activation, so no env needed here.
      ExecStart = "${bleScaleSync}/bin/ble-scale-sync -c /etc/ble-scale-sync/config.yaml";
      Restart = "on-failure";
      RestartSec = "30";
    };
  };

  # Render config.yaml from the agenix profile at activation (keeps birth
  # date/height/gender out of the world-readable Nix store and the public repo).
  # Mirrors the ha-linky options.json bootstrap in home-assistant.nix.
  system.activationScripts.scaleBridgeConfig.text = ''
    set -eu
    install -d -m 0750 -o root -g scale-bridge /etc/ble-scale-sync
    set -a; . /run/agenix/scale-bridge-env; set +a
    cat > /etc/ble-scale-sync/config.yaml <<EOF
    version: 1
    ble:
      adapter: hci0
      scale_mac: "${scaleMac}"
    scale:
      weight_unit: kg
      height_unit: cm
    unknown_user: nearest
    users:
      - name: nsimon
        slug: nsimon
        height: $USER_HEIGHT
        birth_date: "$USER_BIRTH_DATE"
        gender: $USER_GENDER
        is_athlete: false
        # weight-based user matching bounds (kg); single user, so kept wide.
        weight_range:
          min: 50
          max: 150
        last_known_weight: null
    global_exporters:
      - type: webhook
        url: "http://127.0.0.1:${toString shimPort}/measurement"
        headers:
          X-Shim-Key: "$SHIM_KEY"
    runtime:
      continuous_mode: true
    update_check: false
    EOF
    chown root:scale-bridge /etc/ble-scale-sync/config.yaml
    chmod 0640 /etc/ble-scale-sync/config.yaml
  '';
}
