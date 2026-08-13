# OpenRGB built from the 1.0rc2 release candidate, which is the first build
# with working LG monitor support.
#
# Exposed as `pkgs.openrgb-lg` via the repo overlay (see pkgs/overlay.nix)
# because it has two consumers: hosts/beast/rgb/openrgb-lg.nix (systemPackages) and
# hosts/beast/configuration.nix (services.hardware.openrgb.package).
{
  openrgb-with-all-plugins,
  fetchFromGitLab,
}:

let
  # Hoisted out of the override so `src.name` can interpolate it — the fetch and
  # the version it claims to be must move together.
  # See .cursor/rules/fixed-output-names.mdc.
  version = "1.0rc2";
in
openrgb-with-all-plugins.overrideAttrs (_: {
  inherit version;

  src = fetchFromGitLab {
    name = "openrgb-${version}-source";
    owner = "CalcProgrammer1";
    repo = "OpenRGB";
    # Use release candidate 1.0rc2 - stable with LG monitor support
    # Pinned to specific tag so Nix can cache the build
    rev = "release_candidate_1.0rc2";
    hash = "sha256-vdIA9i1ewcrfX5U7FkcRR+ISdH5uRi9fz9YU5IkPKJQ=";
  };

  # Disable default nixpkgs patches - they don't apply to 1.0rc2
  patches = [ ];

  # Fix build issues specific to 1.0rc2
  postPatch = ''
    # Add missing header for ioctl
    sed -i '1i#include <sys/ioctl.h>' scsiapi/scsiapi_linux.c || true

    # Remove systemd and udev install targets that fail in NixOS build
    sed -i '/install_udev_rules/d' OpenRGB.pro
    sed -i '/install_systemd_service/d' OpenRGB.pro
  '';

  # Override install phase to skip problematic systemd/udev installation
  installPhase = ''
    runHook preInstall

    # Install binary
    install -Dm755 openrgb $out/bin/openrgb

    # Install desktop file
    install -Dm644 qt/org.openrgb.OpenRGB.desktop $out/share/applications/org.openrgb.OpenRGB.desktop

    # Install icon
    install -Dm644 qt/org.openrgb.OpenRGB.png $out/share/icons/hicolor/128x128/apps/org.openrgb.OpenRGB.png

    # Install metainfo
    install -Dm644 qt/org.openrgb.OpenRGB.metainfo.xml $out/share/metainfo/org.openrgb.OpenRGB.metainfo.xml

    runHook postInstall
  '';
})
