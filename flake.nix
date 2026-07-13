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
      # so the kernel derivation hash matches what its Cachix cache pre-built
      # (nixos-raspberrypi.cachix.org — see nixConfig below).
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
      url = "github:sipeed/picoclaw/v0.2.9";
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

    # AirTrail — self-hosted flight tracker (johanohly/AirTrail), packaged like
    # sure-nix.
    airtrail-nix = {
      url = "github:nSimonFR/airtrail-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Reactive Resume — self-hosted resume builder (rxresu.me), packaged like
    # sure-nix / airtrail-nix.
    reactive-resume-nix = {
      url = "github:nSimonFR/reactive-resume-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Gramps Web genealogy — same pattern as reactive-resume-nix / sure-nix.
    gramps-web-nix = {
      url = "github:nSimonFR/gramps-web-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # BeaverHabits habit tracker — Python/NiceGUI, packaged via uv2nix. First
    # Python native app here; its flake carries the uv2nix stack itself, so we
    # only pin nixpkgs. See rpi5/beaverhabits.nix.
    beaverhabits-nix = {
      url = "github:nSimonFR/beaverhabits-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Ryot — self-hosted media & life tracker (IgnisDa/ryot), built from source
    # (container-only upstream, not in nixpkgs). Same pattern as the others.
    # NOTE: local path during bring-up; switch to github:nSimonFR/ryot-nix once
    # published. The heavy Rust/Node compile is built locally on the Pi (no
    # prebuild cache — see the garnix deprecation note in nixConfig below).
    ryot-nix = {
      url = "path:/home/nsimon/ryot-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # steipete CLI tools: bump with
    #   sudo nix flake lock --update-input gogcli-src --update-input goplaces-src
    gogcli-src = {
      url = "github:steipete/gogcli/v0.21.0";
      flake = false;
    };
    goplaces-src = {
      url = "github:steipete/goplaces/v0.4.3";
      flake = false;
    };

    # RTK — Rust Token Killer (rtk-ai/rtk). Source-only input (`flake = false`);
    # pkgs/rtk.nix builds it with rustPlatform.buildRustPackage and it's exposed
    # as `pkgs.rtk` via outputs.overlays.rtk. Bumping is a 2-step edit:
    #   1. change the tag in the URL below (e.g. v0.42.4 → v0.43.0)
    #   2. bump `version` in pkgs/rtk.nix to match
    # then `sudo nix flake lock --update-input rtk-src` + rebuild.
    rtk-src = {
      url = "github:rtk-ai/rtk/v0.42.4";
      flake = false;
    };

    # tiny-llm-gate: memory-conscious replacement for LiteLLM.
    # Pinned to a tag; bump the ref to roll forward.
    tiny-llm-gate = {
      url = "github:nSimonFR/tiny-llm-gate/v0.8.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Cyrus — Linear coding-agent dispatcher (cyrusagents/cyrus). Source-only
    # input (`flake = false`): rpi5/cyrus.nix vendors it and builds with pnpm
    # at service start. Tracks the default branch (no tag), so `nix flake
    # update` auto-bumps it; cyrus-build.service rebuilds once per rev change.
    # To pin a specific commit/tag instead, append `/<rev-or-tag>` to the URL.
    cyrus-src = {
      url = "github:cyrusagents/cyrus";
      flake = false;
    };

    # llm-agents.nix: numtide's daily-updated flake of AI coding agent
    # packages. We pull `pi` (pi-coding-agent) from here instead of pinning
    # an upstream tarball ourselves — auto-tracks new releases.
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      # rpi5 kernel/firmware come prebuilt from nixos-raspberrypi's own Cachix.
      # This is the binary cache for the whole rpi5 build — populated upstream via
      # `cachix push` (the nvmd/nixos-raspberrypi repo uses no CI cache service).
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWQnrDg8a8NLFkBE/eCiST04Xhd00="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
    # DEPRECATED: garnix (CI + cache.garnix.io) — REMOVED. garnix shut down
    # 2026-07-15. Nothing here was ever served by it: the kernel is on
    # nixos-raspberrypi.cachix.org (above) and our own heavy builds (e.g. ryot)
    # are compiled locally on the Pi. If a prebuild cache is wanted again, use
    # Cachix (`cachix push`) or a self-hosted attic — same model as the kernel.
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

      # beast's tailnet MagicDNS name — single source of truth for its address.
      # Prefer this over the raw 100.x tailscale IP: it survives a tailnet re-IP
      # and there's exactly one place to change. Resolves from the rpi5 (and the
      # tailnet generally) via MagicDNS.
      beastHost = "beast.gate-mintaka.ts.net";

      # Immich version — SINGLE SOURCE OF TRUTH shared by both hosts. The rpi5
      # runs the Immich *server* from nixpkgs-unstable; beast runs the ML worker
      # (nixos/immich-ml.nix) and Immich REQUIRES server==ML version. Derive it
      # once from the unstable package so the two can never drift: bump nixpkgs-
      # unstable and both hosts move together. (Version is a string attr; reading
      # it forces no build. x86_64 vs aarch64 is irrelevant — same package def.)
      immichVersion =
        (import nixpkgs-unstable {
          system = "x86_64-linux";
          config.allowUnfree = true;
        }).immich.version;

      rpi5Params = {
        tailnetFqdn = "rpi5.gate-mintaka.ts.net";
        inherit beastHost immichVersion;
        beastOllamaUrl = "http://${beastHost}:11434";
        # Tailscale Aperture AI gateway — observability layer in front of tiny-llm-gate.
        # Set to the Aperture hostname after provisioning at aperture.tailscale.com.
        # Until then, points at tiny-llm-gate directly (no-op passthrough).
        apertureUrl = "http://ai.gate-mintaka.ts.net";
        tinyLlmGateUrl = "http://127.0.0.1:4001";
      };
      telegramChatId = 82389391;

      # RTK package overlay — single source of truth so `pkgs.rtk` resolves
      # identically in NixOS modules (via rpi5/overlays.nix) and standalone
      # home-manager configs (the homeConfigurations pkgs below). Builds from
      # the rtk-src flake input; see pkgs/rtk.nix.
      rtkOverlay = final: _prev: {
        rtk = final.callPackage ./pkgs/rtk.nix { rtk-src = inputs.rtk-src; };
      };
    in
    {
      # Exposed so rpi5/overlays.nix can pull the same overlay (DRY).
      overlays.rtk = rtkOverlay;

      # `nix build .#rtk` — standalone build target to isolate rtk's heavy LTO
      # compile from a full rebuild (build it alone first on the rpi5).
      #
      # `.#reactive-resume` — the EXACT rpi5 Reactive Resume derivation (same
      # nixpkgs + appBasePath as the running system). Exposed as a standalone
      # build target so its ~20-min pnpm/turbo compile can be isolated/pinned.
      # (Was prebuilt by garnix CI — DEPRECATED, garnix shut down 2026-07-15;
      # now built locally, or push to Cachix/attic if a cache is wanted.)
      packages = nixpkgs.lib.recursiveUpdate
        (nixpkgs.lib.genAttrs [ "aarch64-linux" "x86_64-linux" "aarch64-darwin" ] (
          system:
          {
            rtk =
              (import nixpkgs {
                inherit system;
                config.allowUnfree = true;
                overlays = [ rtkOverlay ];
              }).rtk;
          }
        ))
        {
          aarch64-linux.reactive-resume =
            self.nixosConfigurations.${rpiconfig}.config.services.reactive-resume.package;
          # Expose Ryot as a standalone target (`nix build .#ryot`) so its heavy
          # Rust LTO + Node build can be isolated/pinned and optionally pushed to
          # a binary cache (Cachix/attic). Built locally on the Pi by default —
          # there is no prebuild CI cache (garnix is deprecated). See rpi5/ryot.nix.
          aarch64-linux.ryot =
            self.nixosConfigurations.${rpiconfig}.config.services.ryot.package;
        };

      nixosConfigurations.${nixconfig} = nixpkgs.lib.nixosSystem rec {
        system = "x86_64-linux";
        specialArgs = {
          inherit inputs outputs username;
          hostname = nixconfig;
          # beast runs the Immich ML worker; version must match the rpi5 server.
          inherit immichVersion;
        };
        modules = [
          ./nixos/configuration.nix
        ];
      };

      nixosConfigurations.${rpiconfig} = inputs.nixos-raspberrypi.lib.nixosSystem {
        # Use our nixpkgs as the base so non-kernel packages hit cache.nixos.org.
        # Kernel/firmware still come from nixos-raspberrypi's overlays (cached on
        # nixos-raspberrypi.cachix.org).
        # This is NOT the same as inputs.nixos-raspberrypi.inputs.nixpkgs.follows (which would
        # break the kernel cache).
        nixpkgs = inputs.nixpkgs;
        specialArgs = {
          inherit inputs outputs username telegramChatId;
          inherit (rpi5Params) tailnetFqdn beastOllamaUrl apertureUrl tinyLlmGateUrl beastHost immichVersion;
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
          inputs.airtrail-nix.nixosModules.airtrail
          inputs.reactive-resume-nix.nixosModules.reactive-resume
          inputs.gramps-web-nix.nixosModules.gramps-web
          inputs.beaverhabits-nix.nixosModules.beaverhabits
          inputs.ryot-nix.nixosModules.ryot
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
                inherit (rpi5Params) tailnetFqdn beastOllamaUrl apertureUrl tinyLlmGateUrl;
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
            # VSCode bundles electron-39.8.10, flagged insecure on 25.11
            # (2026-06) nixpkgs. Permit it so the HM switch (notify hook) builds.
            config.permittedInsecurePackages = [ "electron-39.8.10" ];
            overlays = [ rtkOverlay ];
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
            overlays = [ rtkOverlay ];
          };
          extraSpecialArgs = {
            inherit
              inputs
              outputs
              username
              telegramChatId
              ;
            inherit (rpi5Params) tailnetFqdn beastOllamaUrl apertureUrl tinyLlmGateUrl;
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
            overlays = [ rtkOverlay ];
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
