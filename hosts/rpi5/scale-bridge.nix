# hosts/rpi5/scale-bridge.nix
#
# Loftilla CS20B (a Qingniu "QN-Scale", MAC 24:62:AB:C6:9B:16) → Ryot bridge.
#
# Two native systemd services:
#   * ble-scale-sync.service — third-party Node BLE bridge (KristianP26/ble-scale-sync),
#     packaged in pkgs/services/ble-scale-sync.nix. Connects to the QN scale over BlueZ (onboard
#     hci0), decodes weight + impedance, computes 10 body-composition metrics
#     from the user profile, and POSTs them as JSON to the local shim's webhook.
#     Runs as root: node-ble talks to org.bluez over the system D-Bus, which the
#     default BlueZ policy only grants root/at_console (same rationale as the
#     other root-run local daemons here, e.g. travel-cal-sync).
#   * scale-to-ryot.service — tiny stdlib-Python shim that translates that
#     webhook into a Ryot `createOrUpdateUserMeasurement` GraphQL mutation
#     against Ryot's socket-activation listener on 127.0.0.1:13350 (which wakes
#     it — see ryotUrl below). Runs as the unprivileged
#     `scale-bridge` user. Code + tests live in the nicos-scripts package
#     (hosts/rpi5/scripts/lib/, entry point `scale-to-ryot`).
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
{ config, pkgs, ... }:
let
  shimPort = 8349; # scale-to-ryot shim, 127.0.0.1 only (8347 taken by papra-webhook)
  scaleMac = "24:62:AB:C6:9B:16"; # the QN-Scale (local BT address, not sensitive)
  # Ryot's socket-activation listener + the /ryot/backend route Caddy strips —
  # NOT ryot-backend's own 13352. Ryot sleeps when idle (ryot.nix), and a weigh-in
  # arrives exactly when nobody has been using it, so hitting the backend port
  # directly would connection-refuse against a stopped unit and drop the reading.
  # Going through 13350 wakes the stack and the mutation is queued behind the
  # readyProbe instead.
  ryotUrl = "http://127.0.0.1:13350/ryot/backend/graphql";

  bleScaleSync = pkgs.callPackage ../../pkgs/services/ble-scale-sync.nix { };
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
    # Deliberately NOT ordered against ryot-backend any more. Ryot is socket
    # activated, so it is normally stopped; the shim needs it only at the moment a
    # weigh-in arrives, and reaching 13350 then wakes it. Ordering after it here
    # bought nothing and cost a wake on every boot.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
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
      # No wait-for-Ryot ExecStartPre. It used to poll ryotUrl for up to 120s
      # before serving, which under socket activation is actively wrong twice
      # over: the poll itself WAKES Ryot, so the shim dragged all three tiers up
      # on every boot and restart; and a cold wake is gated by a 180s readyProbe,
      # so the 120s budget could not be met and the unit failed with
      # result 'timeout' (seen on the switch that introduced this). The shim binds
      # its own port and needs Ryot only when a measurement actually arrives.
      ExecStart = "${pkgs.nicos-scripts}/bin/scale-to-ryot";
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
