# LG 38GN950 sphere lighting — video-sync ambient lighting driven by
# wlr-screencopy frames sampled at the screen edges and pushed over USB HID.
#
# Reverse-engineered control protocol: lib27gn950 (subraizada3, MIT).
# Capture: native wlr-screencopy-unstable-v1 via pywayland (no ffmpeg).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3;

  # ------------------------------------------------------------------
  # Wayland protocol bindings, generated at build time so we don't ship
  # pre-generated python in the repo.
  pywaylandProtocols = pkgs.runCommand "pywayland-lg-protocols" {
    nativeBuildInputs = [ python.pkgs.pywayland pkgs.pkg-config pkgs.wayland-scanner ];
  } ''
    mkdir -p $out
    pywayland-scanner \
      -i ${pkgs.wayland-scanner}/share/wayland/wayland.xml \
         ${pkgs.wlr-protocols}/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml \
      -o $out
    touch $out/__init__.py
  '';

  # ------------------------------------------------------------------
  # lib27gn950 — minimal vendored copy of the HID command codec.
  # Upstream: https://github.com/subraizada3/27gn950controller (MIT)
  lib27gn950 = ./lib27gn950.py;

  # ------------------------------------------------------------------
  # Wayland screencopy client.
  screencopy = ./screencopy.py;

  # ------------------------------------------------------------------
  # The ambient daemon.
  daemon = ./lg_sphere_ambient.py;

  # ------------------------------------------------------------------
  # Bundle the python sources into one package directory.
  pythonEnv = python.withPackages (ps: with ps; [ pywayland hid numpy openrgb-python ]);

  lg-sphere-ambient = pkgs.stdenv.mkDerivation {
    pname = "lg-sphere-ambient";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      mkdir -p $out/lib/lg-sphere-ambient
      cp ${lib27gn950}     $out/lib/lg-sphere-ambient/lib27gn950.py
      cp ${screencopy}     $out/lib/lg-sphere-ambient/screencopy.py
      cp ${daemon}         $out/lib/lg-sphere-ambient/lg_sphere_ambient.py
      cp -r ${pywaylandProtocols} $out/lib/lg-sphere-ambient/protocols

      mkdir -p $out/bin
      makeWrapper ${pythonEnv}/bin/python3 $out/bin/lg-sphere-ambient \
        --add-flags "$out/lib/lg-sphere-ambient/lg_sphere_ambient.py" \
        --prefix PYTHONPATH : "$out/lib/lg-sphere-ambient"
    '';
  };

in
{
  # Give the logged-in user access to /dev/hidraw11 (the sphere-lighting
  # endpoint on the LG 38GN950) via group ownership. We previously used
  # systemd-logind's TAG+="uaccess", but the resulting ACL came up with
  # mask::--- on at least one reboot — the user entry was user:nsimon:rw-
  # but the mask collapsed effective rights to nothing, the daemon
  # crash-looped on "unable to open device", and a manual
  # `setfacl -m m::rw` was needed to recover. GROUP="input" MODE="0660"
  # skips the ACL/logind path entirely and is invariant across reboots.
  services.udev.extraRules = ''
    # LG 38GN950 (UltraGear) sphere lighting HID interface
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="043e", ATTRS{idProduct}=="9a8a", GROUP="input", MODE="0660"
  '';

  environment.systemPackages = [ lg-sphere-ambient ];

  # OpenRGB's LG plugin opens /dev/hidraw11 too — hidraw allows concurrent
  # writers, so its writes race ours and the sphere flashes on every
  # disagreement. Disable OpenRGB's LG-monitor detector before the server
  # starts so this daemon is the sole writer; the rest of the OpenRGB
  # device list (RAM, mobo, mouse, gamepad) is unaffected.
  systemd.services.openrgb.preStart = lib.mkAfter ''
    cfg=/var/lib/OpenRGB/OpenRGB.json
    if [ -s "$cfg" ]; then
      ${pkgs.jq}/bin/jq '.Detectors.detectors."LG 27GN950-B Monitor" = false' "$cfg" > "$cfg.tmp" \
        && mv "$cfg.tmp" "$cfg"
    else
      mkdir -p /var/lib/OpenRGB
      printf '{"Detectors":{"detectors":{"LG 27GN950-B Monitor":false}}}' > "$cfg"
    fi
  '';

  # OpenRGB's NVIDIA FE GPU detector dlopens libnvidia-api.so.1, but on
  # NixOS that lib sits in /run/opengl-driver/lib/ — not in the default
  # ld.so search path — so the dlopen silently fails and the GeForce
  # side-logo never gets enumerated. With this env var set,
  # NvAPI_Initialize() returns 0 and NvAPI_EnumPhysicalGPUs() reports 1
  # GPU on a 3080 Ti FE; the "Nvidia NvAPI Illumination" detector then
  # produces an "NVIDIA GeForce RTX 3080 Ti FE" device on the SDK.
  systemd.services.openrgb.environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";

  # User service — starts at login, restarts on failure, ends gracefully on logout.
  systemd.user.services.lg-sphere-ambient = {
    description = "LG 38GN950 sphere-lighting ambient sync";
    after = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];
    wantedBy = [ "default.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''${lg-sphere-ambient}/bin/lg-sphere-ambient \
        --output DP-1 --fps 30 --brightness 12 \
        --openrgb --openrgb-devices all \
        --openrgb-zone-sizes "motherboard/Aura Addressable 1=24,motherboard/Aura Addressable 2=0,motherboard/Aura Addressable 3=8"'';
      Restart = "on-failure";
      RestartSec = "5s";
      # turn the lights off if the service is stopped or fails terminally
      TimeoutStopSec = "5s";
      KillSignal = "SIGTERM";
    };
  };
}
