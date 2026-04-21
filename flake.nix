{
  description = "nSimon nix config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

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
      # Do NOT follow nixpkgs: let nixos-raspberrypi use its own pinned nixpkgs
      # so the kernel derivation hash matches what Garnix/cachix pre-built.
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nix-gaming.url = "github:fufexan/nix-gaming";

    nix-citizen = {
      url = "github:LovingMelody/nix-citizen";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      inputs.nix-gaming.follows = "nix-gaming";
    };

    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # PicoClaw source pinned to a tag. Bumping is a 2-step edit:
    #   1. change the tag in the URL below (e.g. v0.2.6 → v0.3.0)
    #   2. bump `version` default in rpi5/picoclaw/package.nix to match
    # then `sudo nix flake lock --update-input picoclaw-src` + rebuild.
    # Nix TOFUs the new narHash; `vendorHash` only needs refreshing if
    # upstream's go.sum changed between tags (the rebuild will tell you).
    picoclaw-src = {
      url = "github:sipeed/picoclaw/v0.2.6";
      flake = false;
    };

    mac-app-util.url = "github:hraban/mac-app-util";

    nix-flatpak.url = "github:gmodena/nix-flatpak";

    sure-nix = {
      url = "github:nSimonFR/sure-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    for-sure = {
      url = "github:nSimonFR/for-sure?dir=connectors/for-sure";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llmfit = {
      url = "github:AlexsJones/llmfit";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # tiny-llm-gate: memory-conscious replacement for LiteLLM.
    # Pinned to a tag; bump the ref to roll forward.
    tiny-llm-gate = {
      url = "github:nSimonFR/tiny-llm-gate/v0.1.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      rpi5Params = {
        tailnetFqdn = "rpi5.gate-mintaka.ts.net";
        beastOllamaUrl = "http://100.125.240.34:11434";
      };
      telegramChatId = 82389391;
    in
    {
      nixosConfigurations.${nixconfig} = nixpkgs.lib.nixosSystem rec {
        system = "x86_64-linux";
        specialArgs = {
          inherit inputs outputs username;
          hostname = nixconfig;
        };
        modules = [
          ./nixos/configuration.nix
        ];
      };

      nixosConfigurations.${rpiconfig} = inputs.nixos-raspberrypi.lib.nixosSystem {
        # Use our nixpkgs as the base so non-kernel packages hit cache.nixos.org.
        # Kernel/firmware still come from nixos-raspberrypi's overlays (cached on cachix/garnix).
        # This is NOT the same as inputs.nixos-raspberrypi.inputs.nixpkgs.follows (which would
        # break the kernel cache).
        nixpkgs = inputs.nixpkgs;
        specialArgs = {
          inherit inputs outputs username telegramChatId;
          inherit (rpi5Params) tailnetFqdn beastOllamaUrl;
          hostname = rpiconfig;
          nixos-raspberrypi = inputs.nixos-raspberrypi;
          unstablePkgs = import nixpkgs-unstable {
            system = "aarch64-linux";
            config.allowUnfree = true;
          };
        };
        modules = [
          ./rpi5/overlays.nix
          inputs.ragenix.nixosModules.default
          inputs.home-manager.nixosModules.home-manager
          inputs.sure-nix.nixosModules.sure
          inputs.for-sure.nixosModules.default
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm-backup";
              extraSpecialArgs = {
                inherit
                  inputs
                  outputs
                  username
                  telegramChatId
                  ;
                inherit (rpi5Params) tailnetFqdn beastOllamaUrl;
                devSetup = false;
                unstablePkgs = import nixpkgs-unstable {
                  system = "aarch64-linux";
                  config.allowUnfree = true;
                };
              };
              users.${username} = {
                imports = [
                  inputs.ragenix.homeManagerModules.default
                  ./home
                  ./rpi5/home.nix
                ];
              };
            };
          }
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
          ./macos/configuration.nix
        ];
      };

      homeConfigurations = {
        "${username}@${nixconfig}" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
          extraSpecialArgs = {
            inherit
              inputs
              outputs
              username
              telegramChatId
              ;
            inherit (rpi5Params) tailnetFqdn;
            devSetup = false;
            unstablePkgs = import nixpkgs-unstable {
              system = "x86_64-linux";
              config.allowUnfree = true;
              overlays = [
                (final: prev: {
                  code-cursor = prev.code-cursor.overrideAttrs (old: {
                    src = prev.appimageTools.extract {
                      pname = "cursor";
                      inherit (old) version;
                      src = prev.fetchurl {
                        url = "https://downloads.cursor.com/production/475871d112608994deb2e3065dfb7c6b0baa0c54/linux/x64/Cursor-3.0.16-x86_64.AppImage";
                        hash = "sha256-dN8tFSppIpO/P0Thst5uaNzlmfWZDh0Y81Lx1BuSYt0=";
                      };
                    };
                  });
                })
              ];
            };
          };
          modules = [
            inputs.ragenix.homeManagerModules.default
            ./home
            ./nixos/home.nix
          ];
        };

        "${username}@${rpiconfig}" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "aarch64-linux";
            config.allowUnfree = true;
          };
          extraSpecialArgs = {
            inherit
              inputs
              outputs
              username
              telegramChatId
              ;
            inherit (rpi5Params) tailnetFqdn beastOllamaUrl;
            devSetup = false;
            unstablePkgs = import nixpkgs-unstable {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
          };
          modules = [
            inputs.ragenix.homeManagerModules.default
            ./home
            ./rpi5/home.nix
          ];
        };

        "${username}@${macconfig}" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "aarch64-darwin";
            config.allowUnfree = true;
          };
          extraSpecialArgs = {
            inherit
              inputs
              outputs
              username
              telegramChatId
              ;
            inherit (rpi5Params) tailnetFqdn;
            devSetup = true;
            unstablePkgs = import nixpkgs-unstable {
              system = "aarch64-darwin";
              config.allowUnfree = true;
            };
          };
          modules = [
            inputs.ragenix.homeManagerModules.default
            ./home
            ./macos/home.nix
          ];
        };
      };

    };
}
