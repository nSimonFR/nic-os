{
  description = "nSimon nix config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
    home-manager.url = "github:nix-community/home-manager/release-23.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nix-gaming.url = "github:fufexan/nix-gaming";
    mac-app-util.url = "github:hraban/mac-app-util";
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ...
  } @ inputs: let
    inherit (self) outputs;
    username = "nsimon";
    nixconfig = "BeAsT";
    macconfig = "nBook-Pro";
  in {
    nixosConfigurations.${nixconfig} = nixpkgs.lib.nixosSystem rec {
      system = "x86_64-linux";
      specialArgs = {inherit inputs outputs username; hostname=nixconfig;};
      modules = [./nixos/configuration.nix];
    };

    homeConfigurations = {
      ${nixconfig} = home-manager.lib.homeManagerConfiguration rec {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {inherit inputs outputs username;};
        modules = [./home ./nixos/home.nix];
      };

      ${macconfig} = home-manager.lib.homeManagerConfiguration rec {
        pkgs = nixpkgs.legacyPackages.x86_64-darwin;
        extraSpecialArgs = {inherit inputs outputs username;};
        modules = [./home ./macos/home.nix];
      };
    };
  };
}
