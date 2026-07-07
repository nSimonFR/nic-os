# Exiled Exchange 2 — a Path of Exile 2 price-check / trade overlay
# (Kvan7/Exiled-Exchange-2), the community fork of Awakened PoE Trade.
#
# Electron app shipped only as a prebuilt AppImage → wrapped with
# appimageTools.wrapType2, like sidekick.nix / opentrack-tobii.
#
# appimageTools' default FHS already covers Chromium/Electron's big dependency
# set. The extras it does NOT cover are the X11 libs the global-hotkey addon
# (uiohook-napi → node.napi.node) links against — libXtst (XTEST) and libXt —
# without which the hook can't attach and no keystroke is ever caught (same
# failure mode we hit with Sidekick's libuiohook).
{
  appimageTools,
  fetchurl,
}:
let
  pname = "exiled-exchange-2";
  version = "0.15.8"; # upstream tag is v${version}

  src = fetchurl {
    url = "https://github.com/Kvan7/Exiled-Exchange-2/releases/download/v${version}/Exiled-Exchange-2-${version}.AppImage";
    hash = "sha256-xmEvKJkRFJokzOa/6qRqT4+QKfnfjIoAfqP+oDqyxH8=";
  };

  appimageContents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraPkgs = pkgs: [
    pkgs.xorg.libXtst
    pkgs.xorg.libXt
  ];

  # Desktop entry + icon from the AppImage, Exec rewritten to the wrapped binary.
  # StartupWMClass stays "Exiled Exchange 2" so Hyprland rules can match it.
  extraInstallCommands = ''
    install -Dm444 ${appimageContents}/${pname}.png \
      "$out/share/icons/hicolor/512x512/apps/${pname}.png"
    install -Dm444 ${appimageContents}/${pname}.desktop \
      "$out/share/applications/${pname}.desktop"
    substituteInPlace "$out/share/applications/${pname}.desktop" \
      --replace-fail "Exec=AppRun --sandbox %U" "Exec=${pname} %U" \
      --replace-fail "Icon=exiled-exchange-2" "Icon=${pname}"
  '';

  meta = {
    description = "Path of Exile 2 price-check overlay (fork of Awakened PoE Trade)";
    homepage = "https://github.com/Kvan7/Exiled-Exchange-2";
    mainProgram = "exiled-exchange-2";
    platforms = [ "x86_64-linux" ];
  };
}
