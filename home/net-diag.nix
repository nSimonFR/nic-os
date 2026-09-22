{ pkgs, lib, ... }:
{
  # Darwin only: scutil, dscacheutil, ipconfig and the en0 assumptions are macOS.
  home.packages = lib.optionals pkgs.stdenv.isDarwin [
    (pkgs.writeShellApplication {
      name = "dns-probe";
      runtimeInputs = [
        pkgs.bind.dnsutils
        pkgs.coreutils
      ];
      text = builtins.readFile ./scripts/dns-probe.sh;
    })
  ];
}
