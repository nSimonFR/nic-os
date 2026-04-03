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

    nix-steipete-tools = {
      url = "github:openclaw/nix-steipete-tools";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
      # Force our lock file to control nix-steipete-tools so root's timestamps
      # are used, avoiding Nix 2.31.2 lastModified mismatch on nix-openclaw's lock.
      inputs.nix-steipete-tools.follows = "nix-steipete-tools";
    };
    openclaw-source = {
      url = "github:openclaw/openclaw";
      flake = false;
    };

    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mac-app-util.url = "github:hraban/mac-app-util";

    nix-flatpak.url = "github:gmodena/nix-flatpak";

    sure-nix = {
      url = "path:/home/nsimon/sure-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    for-sure-swile = {
      url = "github:nSimonFR/for-sure?dir=connectors/swile";
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
        voiceWebhookPort = 8443;
      };
      telegramChatId = 82389391;
      # Use direct working-tree path so local/untracked skill changes are visible immediately.
      nClawSkillsSource = "path:/home/nsimon/nic-os";
    in
    {
      # OpenClaw expects a single plugin object at flake output `openclawPlugin`.
      # Keep this pure by pinning an explicit target system instead of currentSystem.
      openclawPlugin = import ./rpi5/openclaw/nclaw-skills.nix {
        inherit nixpkgs;
        system = "aarch64-linux";
      };

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
        specialArgs = {
          inherit inputs outputs username telegramChatId;
          inherit (rpi5Params) tailnetFqdn voiceWebhookPort;
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
          inputs.for-sure-swile.nixosModules.default
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
                  nClawSkillsSource
                  telegramChatId
                  ;
                inherit (rpi5Params) tailnetFqdn voiceWebhookPort;
                openclawSource = inputs.openclaw-source;
                devSetup = false;
                unstablePkgs = import nixpkgs-unstable {
                  system = "aarch64-linux";
                  config.allowUnfree = true;
                };
              };
              users.${username} = {
                imports = [
                  inputs.ragenix.homeManagerModules.default
                  inputs.nix-openclaw.homeManagerModules.openclaw
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
            devSetup = false;
            unstablePkgs = import nixpkgs-unstable {
              system = "x86_64-linux";
              config.allowUnfree = true;
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
            overlays = [
              inputs.nix-openclaw.overlays.default
            ];
          };
          extraSpecialArgs = {
            inherit
              inputs
              outputs
              username
              nClawSkillsSource
              telegramChatId
              ;
            inherit (rpi5Params) tailnetFqdn voiceWebhookPort;
            openclawSource = inputs.openclaw-source;
            devSetup = false;
            unstablePkgs = import nixpkgs-unstable {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
          };
          modules = [
            inputs.ragenix.homeManagerModules.default
            inputs.nix-openclaw.homeManagerModules.openclaw
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
