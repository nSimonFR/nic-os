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
    
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nix-citizen = {
      url = "github:LovingMelody/nix-citizen";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mac-app-util.url = "github:hraban/mac-app-util";
  };

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nixos-raspberrypi.cachix.org"
      "https://cache.garnix.io"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWQnrDg8a8NLFkBE/eCiST04Xhd00="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
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
        modules = [
          home-manager.nixosModules.home-manager
          ./nixos/configuration.nix
        ];
      };

      nixosConfigurations.${rpiconfig} = inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = {
          inherit inputs outputs username;
          hostname = rpiconfig;
          nixos-raspberrypi = inputs.nixos-raspberrypi;
        };
        modules = [
          home-manager.nixosModules.home-manager
          ({ inputs, ... }: {
            nixpkgs.overlays = [
              # uv 0.9.26 from release-25.11 fails to build on aarch64-linux; use nixpkgs-unstable
              (final: prev: {
                uv = (import inputs.nixpkgs-unstable {
                  system = prev.stdenv.hostPlatform.system;
                  config.allowUnfree = true;
                }).uv;
              })
              inputs.nix-openclaw.overlays.default
              # Redis cluster tests are flaky in the Nix sandbox
              (final: prev: {
                redis = prev.redis.overrideAttrs (_: {
                  doCheck = false;
                  doInstallCheck = false;
                });
              })
            ];
          })
          ./rpi5/configuration.nix
        ];
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

    };
}
