# Star Citizen fork of opentrack with UMU/Proton Wine prefix fixes.
# https://github.com/Priton-CE/opentrack-StarCitizen (wine-extended-proton branch)
#
# Only used for the NPClient64.dll it installs into /libexec/opentrack — the
# opentrack binary actually run at runtime is the AppImage
# (pkgs/tobii/opentrack-tobii.nix). Service module: nixos/tobii-native.nix.
{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  fetchzip,
  path,
  eigen,
  libevdev,
  libsForQt5,
  cmake,
  ninja,
  npclient-shm-dll,
  onnxruntime,
  opencv4,
  pkg-config,
  procps,
  tobii-stream-engine,
  xorg,
}:

let
  aruco = callPackage "${path}/pkgs/by-name/op/opentrack/aruco.nix" { };
  xplaneSdk = fetchzip {
    url = "https://developer.x-plane.com/wp-content/plugins/code-sample-generation/sdk_zip_files/XPSDK411.zip";
    hash = "sha256-zay5QrHJctllVFl+JhlyTDzH68h5UoxncEt+TpW3UgI=";
  };
in
stdenv.mkDerivation {
  pname = "opentrack-sc";
  version = "2024.1.1-sc";

  src = fetchFromGitHub {
    owner = "Priton-CE";
    repo = "opentrack-StarCitizen";
    rev = "4dd97af0f139f3ddc8f34a24ee961a1046015d3f";
    hash = "sha256-xN4Z1Cpmj8ktqWCQYPZTfqznHrYe28qlKkPoQxHRPJ8=";
  };

  strictDeps = true;

  # Patch tracker-tobii to build on Linux (upstream only enables it on WIN32).
  # The source already uses the cross-platform Stream Engine API; we just need
  # find_library/find_path guards instead of the Windows-only path logic.
  #
  # NOTE: the heredoc body starts at column 0, so Nix strips ZERO indentation
  # from this string. The `cat` line's 6-space indent is therefore part of the
  # (harmless) shell command — keep it exactly as-is so the derivation hash is
  # unchanged by the move out of nixos/tobii-native.nix.
  postPatch = ''
      cat > tracker-tobii/CMakeLists.txt <<'EOF'
if(WIN32)
    set(SDK_TOBII "" CACHE PATH "Tobii Stream Engine path")
    if(SDK_TOBII)
        otr_module(tracker-tobii)
        if("''${CMAKE_SIZEOF_VOID_P}" STREQUAL "4")
            set(arch "x86")
        else()
            set(arch "x64")
        endif()
        target_include_directories(''${self} SYSTEM PRIVATE "''${SDK_TOBII}/include")
        target_link_directories(''${self} PRIVATE "''${SDK_TOBII}/lib/''${arch}")
        set(dll "''${SDK_TOBII}/lib/''${arch}/tobii_stream_engine.dll")
        target_link_libraries(''${self} tobii_stream_engine.lib)
        install(FILES ''${dll} DESTINATION ''${opentrack-libexec})
    endif()
else()
    find_library(TOBII_SE_LIB tobii_stream_engine)
    find_path(TOBII_SE_INCLUDE tobii/tobii.h)
    if(TOBII_SE_LIB AND TOBII_SE_INCLUDE)
        otr_module(tracker-tobii)
        target_include_directories(''${self} SYSTEM PRIVATE "''${TOBII_SE_INCLUDE}")
        target_link_libraries(''${self} "''${TOBII_SE_LIB}")
    endif()
endif()
EOF
  '';

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    libsForQt5.wrapQtAppsHook
    # No wine needed: SDK_WINE is unset (no-wrapper mode), wineg++ not invoked
  ];

  buildInputs = [
    aruco
    tobii-stream-engine
    eigen
    xorg.libXdmcp
    libevdev
    onnxruntime
    opencv4
    procps
    libsForQt5.qtbase
    libsForQt5.qttools
  ];

  cmakeFlags = [
    # SDK_WINE intentionally not set — this source build is only used for
    # NPClient64.dll (overwritten by npclient-shm-dll in postInstall).
    # The actual opentrack binary used at runtime is the AppImage (opentrack-tobii).
    (lib.cmakeFeature "SDK_ARUCO_LIBPATH" "${aruco}/lib/libaruco.a")
    (lib.cmakeFeature "SDK_XPLANE" xplaneSdk.outPath)
  ];

  postInstall = ''
    install -Dt $out/share/icons/hicolor/256x256 $src/gui/images/opentrack.png
    # Replace stock NPClient64.dll (reads Windows named memory FT_SharedMem,
    # requires the wineg++ wrapper) with our POSIX-shm-native version.
    cp ${npclient-shm-dll}/lib/NPClient64.dll $out/libexec/opentrack/NPClient64.dll
  '';

  dontWrapQtApps = true;
  preFixup = ''
    wrapQtApp $out/bin/opentrack
  '';
}
