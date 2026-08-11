# Auburn Sounds Graillon FREE — live voice changer / pitch-correction plugin.
# Redistributable binary release; ships CLAP, LV2 and VST3 for Linux x86_64.
#
# Consumer (systemPackages + VST3_PATH/LV2_PATH): hosts/beast/music-production.nix.
{
  lib,
  stdenvNoCC,
  autoPatchelfHook,
  fetchzip,
  gcc,
  xorg,
}:

stdenvNoCC.mkDerivation rec {
  pname = "graillon-free";
  version = "3.2";

  src = fetchzip {
    # fetchzip's default name is the constant "source", so without this a bumped
    # `url` beside a stale `hash` would silently reuse the old unpacked tree.
    # See pkgs/README.md, "Fixed-output names".
    name = "${pname}-${version}-source";
    url = "https://www.auburnsounds.com/downloads/Graillon-FREE-3.2.zip";
    hash = "sha256-dtbVv3FubdgkcojUnuhbhqfb86hKwtfsV6yEM1lvtcg=";
    stripRoot = false;
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    gcc.cc.lib
    xorg.libX11
  ];

  installPhase = ''
    runHook preInstall

    install -Dm644 "Graillon-FREE-3.2/license.html" \
      "$out/share/doc/${pname}/license.html"
    install -Dm644 "Graillon-FREE-3.2/Graillon 3 Data Sheet.pdf" \
      "$out/share/doc/${pname}/Graillon 3 Data Sheet.pdf"
    install -Dm644 "Graillon-FREE-3.2/Graillon 3 User's Guide.pdf" \
      "$out/share/doc/${pname}/Graillon 3 User's Guide.pdf"
    install -Dm644 "Graillon-FREE-3.2/graillon3-cheat-sheet.jpg" \
      "$out/share/doc/${pname}/graillon3-cheat-sheet.jpg"

    install -Dm755 "Graillon-FREE-3.2/Linux/Linux-64b-CLAP-FREE/Auburn Sounds Graillon 3.clap" \
      "$out/lib/clap/Auburn Sounds Graillon 3.clap"
    mkdir -p "$out/lib/lv2" "$out/lib/vst3"
    cp -r "Graillon-FREE-3.2/Linux/Linux-64b-LV2-FREE/Auburn Sounds Graillon 3.lv2" "$out/lib/lv2/"
    cp -r "Graillon-FREE-3.2/Linux/Linux-64b-VST3-FREE/Auburn Sounds Graillon 3.vst3" "$out/lib/vst3/"
    chmod -R u+w,go+rX "$out/lib/lv2" "$out/lib/vst3"
    find "$out/lib" -type f -name '*.so' -exec chmod 755 {} +

    runHook postInstall
  '';

  meta = {
    description = "Auburn Sounds Graillon FREE live voice changer and pitch-correction plugin (CLAP, LV2, VST3)";
    homepage = "https://www.auburnsounds.com/products/Graillon.html";
    license = lib.licenses.unfreeRedistributable;
    platforms = [ "x86_64-linux" ];
  };
}
