# Tobii Pro Eye Tracker Manager — the Electron calibration/configuration app.
# Repackaged from https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer
{
  stdenv,
  alsa-lib,
  at-spi2-atk,
  autoPatchelfHook,
  cairo,
  cups,
  dbus,
  expat,
  fetchurl,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libxkbcommon,
  makeWrapper,
  mesa,
  nspr,
  nss,
  pango,
  systemd,
  xorg,
  zstd,
}:

stdenv.mkDerivation rec {
  pname = "tobii-pro-eye-tracker-manager";
  version = "2.6.1";

  src = fetchurl {
    # fetchurl names itself after the URL's basename, which carries the
    # version here — but rely on it explicitly, not incidentally.
    # See .cursor/rules/fixed-output-names.mdc.
    name = "${pname}-${version}.pkg.tar.zst";
    url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobiiproeyetrackermanager-2.6.1-1-x86_64.pkg.tar.zst";
    hash = "sha256-IiDsq1GFKEQQCmwev9I0sJgRvqgJm5M1oNvG1dIU7ys=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
    zstd
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libxkbcommon
    mesa
    nspr
    nss
    pango
    systemd        # libudev
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libxcb
  ];

  runtimeDependencies = [
    systemd   # libudev at runtime
  ];

  unpackPhase = ''
    tar xf $src
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/opt $out/bin $out/share

    cp -r opt/TobiiProEyeTrackerManager $out/opt/TobiiProEyeTrackerManager

    # Desktop file and icon
    if [ -d usr/share/applications ]; then
      cp -r usr/share/applications $out/share/
    fi
    if [ -d usr/share/icons ]; then
      cp -r usr/share/icons $out/share/
    fi

    # Wrapper with --no-sandbox (required for Electron without suid chrome-sandbox)
    makeWrapper $out/opt/TobiiProEyeTrackerManager/tobiiproeyetrackermanager $out/bin/tobii-pro-eye-tracker-manager \
      --add-flags "--no-sandbox"

    runHook postInstall
  '';
}
