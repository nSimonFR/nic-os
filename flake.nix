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

    nix-openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    openclaw-source = {
      url = "github:openclaw/openclaw";
      flake = false;
    };

    mac-app-util.url = "github:hraban/mac-app-util";

    nix-flatpak.url = "github:gmodena/nix-flatpak";
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
          inherit inputs outputs username;
          hostname = rpiconfig;
          nixos-raspberrypi = inputs.nixos-raspberrypi;
        };
        modules = [
          ({ inputs, ... }: {
            nixpkgs.overlays = [
              # uv 0.9.26 from release-25.11 fails to build on aarch64-linux; use nixpkgs-unstable
              (final: prev: rec {
                unstablePkgs = import inputs.nixpkgs-unstable {
                  system = prev.stdenv.hostPlatform.system;
                  config.allowUnfree = true;
                };
                uv =
                  unstablePkgs.uv;
                # Keep Ghostfolio current to pick up Yahoo upstream fixes.
                # Temporary pin to 2.247.0 until nixpkgs ships this version.
                ghostfolio = unstablePkgs.ghostfolio.overrideAttrs (old: rec {
                  version = "2.247.0";
                  src = prev.fetchFromGitHub {
                    owner = "ghostfolio";
                    repo = "ghostfolio";
                    tag = version;
                    hash = "sha256-pUFrbPNyHis18Ta/p8DNfM0dz7R7ucGd981gleCFQyw=";
                    leaveDotGit = true;
                    postFetch = ''
                      date -u -d "@$(git -C $out log -1 --pretty=%ct)" +%s%3N > $out/SOURCE_DATE_EPOCH
                      find "$out" -name .git -print0 | xargs -0 rm -rf
                    '';
                  };
                  npmDepsHash = "sha256-eDzoCT28gRhmHxRHKUXl2Gm0Rpso/R5SKaxCuFkZjS8=";
                  npmDeps = prev.fetchNpmDeps {
                    inherit src;
                    hash = npmDepsHash;
                  };
                });
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
            inherit inputs outputs username;
            devSetup = false;
            masterpkgs = import nixpkgs-master {
              system = "x86_64-linux";
              config.allowUnfree = true;
            };
            unstablePkgs = import nixpkgs-unstable {
              system = "x86_64-linux";
              config.allowUnfree = true;
            };
          };
          modules = [
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
            inherit inputs outputs username nClawSkillsSource;
            openclawSource = inputs.openclaw-source;
            devSetup = false;
            unstablePkgs = import nixpkgs-unstable {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
            masterpkgs = import nixpkgs-master {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
          };
          modules = [
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
            inherit inputs outputs username;
            devSetup = true;
            masterpkgs = import nixpkgs-master {
              system = "aarch64-darwin";
              config.allowUnfree = true;
            };
            unstablePkgs = import nixpkgs-unstable {
              system = "aarch64-darwin";
              config.allowUnfree = true;
            };
          };
          modules = [
            ./home
            ./macos/home.nix
          ];
        };
      };

    };
}
