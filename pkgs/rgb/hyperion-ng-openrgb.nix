# Hyperion.ng built with OpenRGB output support (-DENABLE_OPENRGB=ON).
#
# Service module (user unit, firewall ports): nixos/rgb/hyperion-openrgb.nix.
{
  hyperion-ng,
  jsoncpp,
}:

hyperion-ng.overrideAttrs (oldAttrs: {
  cmakeFlags = oldAttrs.cmakeFlags ++ [
    "-DENABLE_OPENRGB=ON"
  ];

  buildInputs = oldAttrs.buildInputs ++ [
    jsoncpp
  ];
})
