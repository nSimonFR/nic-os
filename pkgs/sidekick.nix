# Sidekick — a companion trade tool for Path of Exile 1 & 2 (Sidekick-Poe/Sidekick).
# Price-checks items, checks map modifiers, cheat sheets, etc.
#
# Upstream ships only a prebuilt AppImage (not in nixpkgs, no source build), so
# we wrap it with appimageTools.wrapType2 — same approach as opentrack-tobii in
# nixos/tobii-native.nix.
#
# It's a framework-dependent .NET app (a Photino/webview UI), so unlike a
# self-contained AppImage it needs its runtime libs injected via extraPkgs:
#   - dotnet-runtime_8  → the .NET 8 shared framework the app is published against
#   - webkitgtk_4_1     → the WebKitGTK 4.1 webview the UI renders in
#   - libnotify         → libnotify.so.4, a hard DT_NEEDED of Photino.Native.so
#                         (dlopen fails without it even with notifications disabled)
#   - xsel              → clipboard access used for in-game item price checks
# (mirrors upstream's documented deps: dotnet-runtime-8.0, webkit2gtk-4.1, xsel;
#  libnotify is implied by the Photino native lib but undocumented upstream.)
{
  appimageTools,
  fetchurl,
}:
let
  pname = "sidekick-poe";
  version = "2026.7.1"; # upstream tag is v${version}

  src = fetchurl {
    url = "https://github.com/Sidekick-Poe/Sidekick/releases/download/v${version}/Sidekick-linux-stable.AppImage";
    hash = "sha256-7W+9179+ILBDfqgFuP6+SwvBpwIjTpEEwkZpwputEVU=";
  };

  # Extracted AppImage tree — used only to lift out the bundled .desktop + icon
  # so the app shows up in rofi/dmenu (wrapType2 alone installs just the binary).
  appimageContents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraPkgs = pkgs: [
    pkgs.dotnet-runtime_8
    pkgs.webkitgtk_4_1
    pkgs.libnotify
    pkgs.xsel

    # Global hotkey capture: SharpHook ships libuiohook.so, which is X11-only on
    # Linux (XRecord to listen, XTest to inject). Without these its dlopen fails
    # silently — the C# keybind handlers still "initialize" but the native hook
    # attaches to nothing, so no keystroke is ever caught. On Wayland it hooks
    # the shared Xwayland, so it only sees keys while an XWayland window (the
    # game, under Proton) is focused — which is fine for the in-game use case.
    pkgs.xorg.libX11
    pkgs.xorg.libXtst
    pkgs.xorg.libXt
    pkgs.xorg.libXinerama
    pkgs.libxkbcommon

    # Tray icon: NotificationIcon.NET ships libnotification_icon.so, which needs
    # libappindicator3 (+ gtk3, pulled in via webkitgtk). Missing it only trips
    # an ErrorBoundary for the tray, not the whole app — but this clears it.
    pkgs.libappindicator-gtk3
  ];

  # Ship a desktop entry pointing at the wrapped binary (Exec/Icon rewritten from
  # the AppImage's own Sidekick.desktop). Keep StartupWMClass=Sidekick so Wayland
  # window rules can still match it.
  extraInstallCommands = ''
    install -Dm444 ${appimageContents}/Sidekick.png \
      "$out/share/icons/hicolor/256x256/apps/${pname}.png"
    install -Dm444 ${appimageContents}/Sidekick.desktop \
      "$out/share/applications/${pname}.desktop"
    substituteInPlace "$out/share/applications/${pname}.desktop" \
      --replace-fail "Exec=Sidekick" "Exec=${pname}" \
      --replace-fail "Icon=Sidekick" "Icon=${pname}"
  '';

  meta = {
    description = "Companion trade tool for Path of Exile 1 & 2";
    homepage = "https://sidekick-poe.github.io/";
    mainProgram = "sidekick-poe";
    platforms = [ "x86_64-linux" ];
  };
}
