# USB communication daemon for Tobii hardware.
# Repackaged from https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer
{
  stdenv,
  autoPatchelfHook,
  fetchurl,
  systemd,
  zstd,
}:

stdenv.mkDerivation rec {
  pname = "tobii-usb-service";
  version = "2.1.5";

  src = fetchurl {
    # fetchurl names itself after the URL's basename, which carries the
    # version here — but rely on it explicitly, not incidentally.
    # See .cursor/rules/fixed-output-names.mdc.
    name = "${pname}-${version}.pkg.tar.zst";
    url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobiiusbservice-2.1.5-1-x86_64.pkg.tar.zst";
    hash = "sha256-+QLdjfJ7oLCAU66R49KHHU/drhXRUlBYRmjLpCYlmnk=";
  };

  nativeBuildInputs = [ autoPatchelfHook zstd ];
  buildInputs = [
    systemd # libudev
  ];

  unpackPhase = ''
    tar xf $src
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp usr/bin/tobiiusbserviced $out/bin/
    cp usr/local/lib/tobiiusb/*.so $out/lib/

    # Bundled libs reference each other
    addAutoPatchelfSearchPath $out/lib
    runHook postInstall
  '';
}
