{
  description = "nSimon nix config";

  inputs = {
    nixpkgs.url = github:nixos/nixpkgs/nixos-23.05;
    home-manager.url = github:nix-community/home-manager/release-23.05;
    nix-gaming.url = github:fufexan/nix-gaming;
    mac-app-util.url = github:hraban/mac-app-util;
    darwin.url = github:lnl7/nix-darwin;

    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
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
        extraSpecialArgs = {inherit inputs outputs username;};
        modules = [./home ./nixos/home.nix];
      };

      ${macconfig} = home-manager.lib.homeManagerConfiguration rec {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        extraSpecialArgs = {inherit inputs outputs username;};
        modules = [./home ./macos/home.nix];
      };
    };
  };
}
