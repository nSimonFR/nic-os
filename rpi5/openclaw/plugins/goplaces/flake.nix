{
  description = "openclaw plugin: goplaces (narHash-compatible wrapper for Nix 2.31+)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    root = {
      url = "github:openclaw/nix-steipete-tools?rev=6352c8247b3b889d7f17bce1f09d6c58fd34932c&narHash=sha256-nfCSSyNU97XpKVPgo6mODBwrVeTOuMCl3i18QuGjpN0=";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, root }:
    let
      lib = nixpkgs.lib;
      systems = builtins.attrNames root.packages;
      pluginFor =
        system:
        let
          goplaces = (root.packages.${system} or { }).goplaces or null;
        in
        if goplaces == null then
          null
        else
          {
            name = "goplaces";
            skills = [ ./skills/goplaces ];
            packages = [ goplaces ];
            needs = {
              stateDirs = [ ];
              requiredEnv = [ ];
            };
          };
    in
    {
      packages = lib.genAttrs systems (
        system:
        let
          g = (root.packages.${system} or { }).goplaces or null;
        in
        if g == null then { } else { goplaces = g; }
      );
      openclawPlugin = pluginFor;
    };
}
