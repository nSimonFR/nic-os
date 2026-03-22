{
  description = "openclaw plugin: summarize (narHash-compatible wrapper for Nix 2.31+)";

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
          summarize = (root.packages.${system} or { }).summarize or null;
        in
        if summarize == null then
          null
        else
          {
            name = "summarize";
            skills = [ ./skills/summarize ];
            packages = [ summarize ];
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
          s = (root.packages.${system} or { }).summarize or null;
        in
        if s == null then { } else { summarize = s; }
      );
      openclawPlugin = pluginFor;
    };
}
