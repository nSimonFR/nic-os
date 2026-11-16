# Rex CLI + server (Superlogical). `rex new` starts a per-user server on demand;
# the Rex Beta.app GUI connects to the same socket once installed.
{ inputs, pkgs, ... }:
{
  home.packages = [ inputs.rex.packages.${pkgs.stdenv.hostPlatform.system}.rex ];
}
