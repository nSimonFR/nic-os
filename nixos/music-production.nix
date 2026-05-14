{ pkgs, lib, ... }:
let
  talVocoder2 = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "tal-vocoder-2";
    version = "2023-07-21";

    src = pkgs.fetchzip {
      url = "https://tal-software.com/downloads/plugins/TAL-Vocoder-2_64_linux.zip";
      hash = "sha256-QrYjoD9fs/JotlM86ZN/3N2Svcwds7xvXYudKuKt9gI=";
      stripRoot = false;
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [
      alsa-lib
      freetype
      gcc.cc.lib
      stdenv.cc.cc.lib
    ];

    installPhase = ''
      runHook preInstall

      install -Dm644 ReadmeLinux.txt \
        $out/share/doc/${pname}/ReadmeLinux.txt

      install -Dm755 TAL-Vocoder-2.clap \
        $out/lib/clap/TAL-Vocoder-2.clap
      install -Dm755 libTAL-Vocoder-2.so \
        $out/lib/vst/libTAL-Vocoder-2.so
      mkdir -p $out/lib/vst3
      cp -r TAL-Vocoder-2.vst3 $out/lib/vst3/

      runHook postInstall
    '';

    meta = {
      description = "TAL-Vocoder-2 free vocoder plugin (CLAP, VST2, VST3)";
      homepage = "https://tal-software.com/products/tal-vocoder";
      license = lib.licenses.unfreeRedistributable;
      platforms = [ "x86_64-linux" ];
    };
  };

  graillonFree = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "graillon-free";
    version = "3.2";

    src = pkgs.fetchzip {
      url = "https://www.auburnsounds.com/downloads/Graillon-FREE-3.2.zip";
      hash = "sha256-dtbVv3FubdgkcojUnuhbhqfb86hKwtfsV6yEM1lvtcg=";
      stripRoot = false;
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [
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
  };
in
{
  # Pro-audio basics for REAPER on PipeWire.
  # Keep global PipeWire timing in nixos/audio.nix untouched; REAPER can opt into
  # JACK/PipeWire with `pw-jack reaper` without changing the desktop audio graph.
  security.rtkit.enable = true;
  services.pipewire.jack.enable = true;

  environment.systemPackages = with pkgs; [
    reaper
    reaper-sws-extension
    reaper-reapack-extension

    # Plugin formats / bridges / routing helpers
    talVocoder2
    graillonFree
    yabridge
    yabridgectl
    wineWowPackages.waylandFull
    winetricks
    qpwgraph
    pipewire.jack # provides pw-jack for JACK clients on PipeWire

    # Native Linux pitch-correction alternatives available in nixpkgs.
    # MAutoPitch is not distributed as a native Linux plugin; use yabridge
    # with its Windows VST build if you still want that specific plugin.
    autotalent
    x42-plugins
    lsp-plugins
    distrho-ports
  ];
}
