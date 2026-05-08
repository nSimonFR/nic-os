{ stdenv, fetchurl, autoPatchelfHook, lib }:
# Drop-in usbmuxd replacement that talks to iOS devices over the network
# (mDNS-discovered) instead of USB. Upstream ships a glibc-linked aarch64
# binary; autoPatchelfHook fixes the dynamic interpreter for NixOS.
stdenv.mkDerivation (finalAttrs: {
  pname = "netmuxd";
  version = "0.3.2";

  src = fetchurl {
    url = "https://github.com/jkcoxson/netmuxd/releases/download/v${finalAttrs.version}/netmuxd-aarch64-unknown-linux-gnu.tar.gz";
    sha256 = "191c4i7516q9xkl8qcj3n6vr78pb4mqqiib5li4lx9lklg1fhc9l";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 netmuxd $out/bin/netmuxd
    runHook postInstall
  '';

  meta = with lib; {
    description = "Network multiplexer for iOS lockdownd (drop-in usbmuxd replacement)";
    homepage = "https://github.com/jkcoxson/netmuxd";
    license = licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "netmuxd";
  };
})
