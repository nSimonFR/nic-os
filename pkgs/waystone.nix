# Waystone — a Wayland-native Path of Exile 2 price-check overlay (kriskruse/Waystone).
#
# Unlike the Electron tools (Exiled Exchange 2, Awakened PoE Trade), Waystone is
# built for Hyprland/wlroots: it renders through gtk4-layer-shell and binds its
# global hotkeys via the xdg-desktop-portal GlobalShortcuts API — the two things
# Electron refuses to do on Wayland. So it needs NO XWayland hacks or `pass` binds.
#
# Two processes over a Unix socket:
#   - poed  (Python 3.12 + GTK4/gtk4-layer-shell) — overlay, portal hotkeys,
#            wl-clipboard, xdotool Ctrl+C injection into the (XWayland) game.
#   - brain (Node/TS, esbuild-bundled) — item parser + trade2/poe2scout pricing.
#            poed spawns it as `node dist/server.mjs`; parser/data vendored from
#            Exiled Exchange 2 under brain/vendor/ee2/public.
#
# Two NixOS-specific fixes vs upstream's Arch PKGBUILD:
#   1. poed/__main__.py hardcodes LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so
#      (absent on NixOS) — the wrapper sets LD_PRELOAD to the Nix store path, so
#      poed's own re-exec is skipped.
#   2. __main__.py calls GLibUnix.signal_add(), which doesn't exist in nixpkgs'
#      pygobject; the classic GLib.unix_signal_add() does — patched below.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  buildNpmPackage,
  python312,
  wrapGAppsHook4,
  gobject-introspection,
  makeWrapper,
  gtk4,
  gtk4-layer-shell,
  glib,
  gdk-pixbuf,
  pango,
  graphene,
  librsvg,
  gsettings-desktop-schemas,
  nodejs,
  xdotool,
  wl-clipboard,
}:
let
  version = "0.1.1";

  src = fetchFromGitHub {
    owner = "kriskruse";
    repo = "Waystone";
    rev = "v${version}";
    hash = "sha256-Vc18ROvsjH7i4yIfD5Pm7ewkko1rmRoeg4eZU0BXCCw=";
  };

  # Node "brain": esbuild bundle (self-contained, no runtime node_modules) plus
  # the vendored EE2 game data the bundle resolves at ../vendor/ee2/public.
  brain = buildNpmPackage {
    pname = "waystone-brain";
    inherit version src;
    sourceRoot = "${src.name}/brain";
    npmDepsHash = "sha256-AxaolaQHkRIVOozvlPmOSkFfcuSRuPZ76/aTgPSTPBQ=";
    # `npm run build` (esbuild) is the default npmBuildScript; keep it.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/dist" "$out/vendor/ee2"
      cp dist/server.mjs "$out/dist/"
      cp -r vendor/ee2/public "$out/vendor/ee2/public"
      runHook postInstall
    '';
  };

  # Python "poed" library (installed into a python env below).
  poed = python312.pkgs.buildPythonPackage {
    pname = "waystone-poed";
    inherit version src;
    pyproject = true;
    sourceRoot = "${src.name}/poed";
    build-system = [ python312.pkgs.setuptools ];
    dependencies = with python312.pkgs; [
      pygobject3
      numpy
      opencv4
      pycairo
    ];
    # Fix #2: GLibUnix.signal_add → GLib.unix_signal_add (GLib is already imported).
    postPatch = ''
      substituteInPlace poed/__main__.py \
        --replace-fail "GLibUnix.signal_add(" "GLib.unix_signal_add("
    '';
    # Importing poed pulls in GTK/GI + a display; can't run in the sandbox.
    doCheck = false;
    pythonImportsCheck = [ ];
    # pyproject declares "opencv-python"; nixpkgs provides the same cv2 module as
    # `opencv4` (dist name "opencv"), so the runtime-deps name check misfires.
    dontCheckRuntimeDeps = true;
  };

  pythonEnv = python312.withPackages (_: [ poed ]);
in
stdenvNoCC.mkDerivation {
  pname = "waystone";
  inherit version;

  dontUnpack = true;

  # wrapGAppsHook4 + gobject-introspection populate GI_TYPELIB_PATH (Gtk-4.0,
  # Gtk4LayerShell-1.0, GLibUnix-2.0, …), XDG_DATA_DIRS (gsettings schemas) and
  # the gdk-pixbuf loaders onto the launcher.
  nativeBuildInputs = [
    wrapGAppsHook4
    gobject-introspection
    makeWrapper
  ];
  buildInputs = [
    gtk4
    gtk4-layer-shell
    glib
    gdk-pixbuf
    pango
    graphene
    librsvg
    gsettings-desktop-schemas
  ];

  installPhase = ''
    runHook preInstall
    makeWrapper ${pythonEnv}/bin/python "$out/bin/waystone" \
      --add-flags "-m poed" \
      --set LD_PRELOAD ${gtk4-layer-shell}/lib/libgtk4-layer-shell.so \
      --set WAYSTONE_BRAIN_DIR ${brain} \
      --prefix PATH : ${lib.makeBinPath [ nodejs xdotool wl-clipboard ]}
    runHook postInstall
  '';

  meta = {
    description = "Wayland-native Path of Exile 2 price-check overlay (Hyprland, gtk4-layer-shell + portal hotkeys)";
    homepage = "https://github.com/kriskruse/Waystone";
    license = with lib.licenses; [ agpl3Plus mit ]; # project AGPL; vendored EE2 data MIT
    mainProgram = "waystone";
    platforms = [ "x86_64-linux" ];
  };
}
