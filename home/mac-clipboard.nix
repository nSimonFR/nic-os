{ pkgs, lib, ... }:
{
  # `pbpaste` on Linux hosts, pulling from the Mac over SSH. The Mac has the
  # real one, so it gets nothing.
  home.packages = lib.optionals pkgs.stdenv.isLinux [
    (pkgs.writeShellApplication {
      name = "pbpaste";
      runtimeInputs = [
        pkgs.openssh
        pkgs.gnutar
        pkgs.coreutils
      ];
      text = ''
        MAC_CLIP_JS=${./scripts/mac-clip.js}
      ''
      + builtins.readFile ./scripts/pbpaste.sh;
    })
  ];
}
