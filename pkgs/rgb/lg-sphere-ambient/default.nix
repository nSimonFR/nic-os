# LG 38GN950 sphere lighting — video-sync ambient lighting driven by
# wlr-screencopy frames sampled at the screen edges and pushed over USB HID.
#
# Reverse-engineered control protocol: lib27gn950 (subraizada3, MIT).
# Capture: native wlr-screencopy-unstable-v1 via pywayland (no ffmpeg).
#
# Service module (udev rule, OpenRGB LG-detector disable, user unit):
# hosts/beast/rgb/lg-sphere-ambient.nix.
{
  stdenv,
  makeWrapper,
  pkg-config,
  python3,
  runCommand,
  wayland-scanner,
  wlr-protocols,
}:

let
  python = python3;

  # ------------------------------------------------------------------
  # Wayland protocol bindings, generated at build time so we don't ship
  # pre-generated python in the repo.
  pywaylandProtocols = runCommand "pywayland-lg-protocols" {
    nativeBuildInputs = [ python.pkgs.pywayland pkg-config wayland-scanner ];
  } ''
    mkdir -p $out
    pywayland-scanner \
      -i ${wayland-scanner}/share/wayland/wayland.xml \
         ${wlr-protocols}/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml \
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
in
stdenv.mkDerivation {
  pname = "lg-sphere-ambient";
  version = "0.1.0";
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
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
}
