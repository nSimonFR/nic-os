{ inputs, config, lib, pkgs, ... }:
let
  apps = pkgs.buildEnv {
    name = "home-manager-applications";
    paths = config.home.packages;
    pathsToLink = [ "/Applications" ];
  };
  mac-app-util = inputs.mac-app-util.packages.${pkgs.stdenv.system}.default;
in
{
  # Home-manager does not link installed applications to the user environment. This means apps will not show up
  # in spotlight, and when launched through the dock they come with a terminal window. This is a workaround.
  # Upstream issue: https://github.com/nix-community/home-manager/issues/1341
  home.activation.addApplications = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    fromDir="${apps}/Applications/"
    toDir="$HOME/Applications/Home Manager Trampolines"
    ${mac-app-util}/bin/mac-app-util sync-trampolines "$fromDir" "$toDir"
  '';
}
