{
  description = "openclaw plugin: gogcli (narHash-compatible wrapper for Nix 2.31+)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    root = {
      url = "github:openclaw/nix-steipete-tools?rev=dbf0a31a57407d9140e32357ea8d0215bd9feed9&narHash=sha256-QkPl/Rgk9DXgaVNhjvHHHjy5e81j+MzcVOouZRdUTLA=";
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
          gogcli = (root.packages.${system} or { }).gogcli or null;
        in
        if gogcli == null then
          null
        else
          {
            name = "gogcli";
            skills = [ ./skills/gog ];
            packages = [ gogcli ];
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
          g = (root.packages.${system} or { }).gogcli or null;
        in
        if g == null then { } else { gogcli = g; }
      );
      openclawPlugin = pluginFor;
    };
}
