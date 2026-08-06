# OpenTrack AppImage with the Tobii input plugin — the opentrack binary that
# actually runs at runtime (Tobii → UDP relay). The source build
# (pkgs/tobii/opentrack-sc.nix) only exists for its NPClient64.dll.
{
  appimageTools,
  fetchurl,
}:

appimageTools.wrapType2 {
  pname = "opentrack-tobii";
  version = "2026.1.0";

  src = fetchurl {
    url = "https://github.com/megagtrwrath/opentrack-appimage-ci/releases/download/opentrack-2026.1.0-20260312-072213Z/OpenTrack-TOBII-2026.1.0-x86_64.AppImage";
    hash = "sha256-1h/W3NMMrNiBHD3dlebIdjfFf3tALsCexIAlB6E7mK8=";
  };
}
