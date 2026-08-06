{ pkgs, ... }:
let
  graillonFree = pkgs.callPackage ../pkgs/desktop/graillon-free.nix { };
in
{
  environment.systemPackages = [
    pkgs.audacity
    graillonFree
  ];

  environment.variables = {
    VST3_PATH = "${graillonFree}/lib/vst3";
    LV2_PATH = "${graillonFree}/lib/lv2";
  };
}
