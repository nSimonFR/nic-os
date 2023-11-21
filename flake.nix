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
  in {
    nixosConfigurations = {
      desktop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {inherit inputs outputs;};
        modules = [./nixos/configuration.nix];
      };
    };

    homeConfigurations = {
      desktop = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {inherit inputs outputs;};
        modules = [
          ./modules/home.nix
          {
            home = {
              username = "nsimon";
              homeDirectory = "/home/nsimon";
            };
            systemd.user.startServices = "sd-switch";
          }
        ];
      };

      macbookpro = home-manager.lib.homeManagerConfiguration rec {
        pkgs = nixpkgs.legacyPackages.x86_64-darwin;
        extraSpecialArgs = {inherit inputs outputs;};
        modules = [
          ./modules/home.nix
          ./macos/applications.nix
          {
            home = {
              homeDirectory = "/Users/nsimon";
              username = "nsimon";
            };
            xdg.configFile."nix/nix.conf".text = ''
              experimental-features = nix-command flakes
            '';
          }
        ];
      };
    };
  };
}
