{
  description = "nSimon nix config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    darwin = {
      url = "github:lnl7/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nix-gaming = {
      url = "github:fufexan/nix-gaming?rev=8b636f0470cb263aa1472160457f4b2fba420425";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-citizen = {
      url = "github:3kynox/nix-citizen?ref=fix/eac-error-70003-icu-dotnet";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mac-app-util.url = "github:hraban/mac-app-util";

    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
  };

  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nixpkgs-master,
      home-manager,
      darwin,
      ...
    }@inputs:
    let
      inherit (self) outputs;
      username = "nsimon";
      nixconfig = "BeAsT";
      macconfig = "nBookPro";
      rpiconfig = "rpi5";
    in
    {
      nixosConfigurations.${nixconfig} = nixpkgs.lib.nixosSystem rec {
        system = "x86_64-linux";
        specialArgs = {
          inherit inputs outputs username;
          hostname = nixconfig;
        };
        modules = [ ./nixos/configuration.nix ];
      };

      nixosConfigurations.${rpiconfig} = inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = {
          inherit inputs outputs username;
          hostname = rpiconfig;
          nixos-raspberrypi = inputs.nixos-raspberrypi;
        };
        modules = [ ./rpi5/configuration.nix ];
      };

      darwinConfigurations.${macconfig} = darwin.lib.darwinSystem rec {
        system = "aarch64-darwin";
        specialArgs = {
          inherit inputs outputs username;
          hostname = macconfig;
        };
        modules = [
          home-manager.darwinModules.home-manager
          ./macos/configuration.nix
        ];
      };

      homeConfigurations = {
        ${nixconfig} = home-manager.lib.homeManagerConfiguration rec {
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
          extraSpecialArgs = {
            inherit inputs outputs username;
            unstablepkgs = import nixpkgs-unstable {
              system = "x86_64-linux";
              config.allowUnfree = true;
            };
            masterpkgs = import nixpkgs-master {
              system = "x86_64-linux";
              config.allowUnfree = true;
            };
          };
          modules = [
            ./home
            ./nixos/home.nix
          ];
        };

        ${macconfig} = home-manager.lib.homeManagerConfiguration rec {
          pkgs = import nixpkgs {
            system = "aarch64-darwin";
            config.allowUnfree = true;
          };
          extraSpecialArgs = {
            inherit inputs outputs username;
            unstablepkgs = import nixpkgs-unstable {
              system = "aarch64-darwin";
              config.allowUnfree = true;
            };
            masterpkgs = import nixpkgs-master {
              system = "aarch64-darwin";
              config.allowUnfree = true;
            };
          };
          modules = [
            ./home
            ./macos/home.nix
          ];
        };

        ${rpiconfig} = home-manager.lib.homeManagerConfiguration rec {
          pkgs = import nixpkgs {
            system = "aarch64-linux";
            config.allowUnfree = true;
          };
          extraSpecialArgs = {
            inherit inputs outputs username;
            unstablepkgs = import nixpkgs-unstable {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
            masterpkgs = import nixpkgs-master {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
          };
          modules = [
            ./home
            ./rpi5/home.nix
          ];
        };
      };
    };
}
