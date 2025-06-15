{
  description = "nSimon nix config";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs/release-25.05;
    nixpkgs-unstable.url = github:NixOS/nixpkgs/nixpkgs-unstable;

    darwin = {
      url = github:lnl7/nix-darwin/nix-darwin-25.05;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = github:nix-community/home-manager/release-25.05;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    quickshell = {
      url = "github:quickshell-mirror/quickshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mac-app-util.url = github:hraban/mac-app-util;
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    home-manager,
    darwin,
    ...
  } @ inputs: let
    inherit (self) outputs;
    username = "nsimon";
    nixconfig = "BeAsT";
    macconfig = "nBookPro";
  in {
    nixosConfigurations.${nixconfig} = nixpkgs.lib.nixosSystem rec {
      system = "x86_64-linux";
      specialArgs = {inherit inputs outputs username; hostname=nixconfig;};
      modules = [./nixos/configuration.nix];
    };

    darwinConfigurations.${macconfig} = darwin.lib.darwinSystem rec {
      system = "aarch64-darwin";
      specialArgs = {inherit inputs outputs username; hostname=macconfig;};
      modules = [home-manager.darwinModules.home-manager ./macos/configuration.nix];
    };

    homeConfigurations = {
      ${nixconfig} = home-manager.lib.homeManagerConfiguration rec {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {
          inherit inputs outputs username;
          unstablepkgs = nixpkgs-unstable.legacyPackages.x86_64-linux.pkgs;
        };
        modules = [./home ./nixos/home.nix];
      };

      ${macconfig} = home-manager.lib.homeManagerConfiguration rec {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        extraSpecialArgs = {
          inherit inputs outputs username;
          unstablepkgs = nixpkgs-unstable.legacyPackages.aarch64-darwin.pkgs;
        };
        modules = [./home ./macos/home.nix];
      };
    };
  };
}
