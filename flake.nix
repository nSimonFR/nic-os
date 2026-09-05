{
  description = "nSimon nix config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Ollama only. The nixpkgs-unstable pin above carries ollama 0.32.4, which
    # refuses to pull qwen3.8:27b (registry answers 412 "requires a newer version
    # of Ollama" — the model landed upstream in 0.32.12). Bumping the shared
    # nixpkgs-unstable to get it would also move the rpi5 (home-assistant,
    # immich, papra, uv) and force a from-source onnxruntime-cuda rebuild for
    # hosts/beast/immich-ml.nix, whose immich must stay in lock-step with the
    # rpi5's — so keep the newer tree scoped to the one package that needs it.
    # Rev is nixpkgs-unstable @ 2026-08-22, ollama 0.32.14.
    nixpkgs-ollama.url = "github:NixOS/nixpkgs/8bf1308761517c52cf3a5f8565a27ae789db1047";

    # Home Assistant only, same reasoning as nixpkgs-ollama above — and the same
    # reason it cannot just ride the shared nixpkgs-unstable pin.
    #
    # HA migrates /var/lib/hass/.storage in place on first start of a newer
    # release and refuses to read it back afterwards ("Storage file http has
    # version 2 which is newer than the max supported version 1"). So the pin
    # feeding it is a one-way ratchet: it may only ever move forward, and a
    # rebuild that moves it backward bricks HA until it is bumped again.
    #
    # That is not hypothetical. On 2026-08-23 a rebuild off a lock-file bump
    # (generation 1088) shipped HA 2026.8.2, which migrated .storage to the new
    # schema; the next rebuild from main (generation 1089, same day) snapped the
    # shared unstable pin back to 2026.7.4 and HA crash-looped for six days —
    # 60k restarts, unnoticed, because the homepage tile kept serving the last
    # cached counts. Scoping HA to its own input means a shared-pin bump can no
    # longer walk it backwards.
    #
    # Rev is nixpkgs-unstable @ 2026-08-27, home-assistant 2026.8.3. Only ever
    # replace this with a rev carrying an equal or newer HA.
    nixpkgs-hass.url = "github:NixOS/nixpkgs/c27cdad491a991b11ed731760aa2ef8db0cb0410";

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

    # Hermes Agent (NousResearch/hermes-agent) — Python+Node AI agent, a full
    # flake carrying its own uv2nix stack (like beaverhabits-nix, we only pin
    # nixpkgs; forcing the pyproject/uv2nix inputs to follow breaks the build).
    # The rpi5 Telegram agent (succeeded PicoClaw) — see hosts/rpi5/hermes/hermes.nix.
    # We use only the lean `messaging` package variant.
    #
    # ⚠ HELD AT A TAG — see the `ref` in the url below, not this comment, for
    #   which one. Upstream tracks its default branch, and once `nix flake
    #   update` walked this input onto a rev whose nix/lib.nix asks for a nodejs
    #   major our nixpkgs release does not carry, the rpi5 config stopped
    #   EVALUATING entirely — not just hermes:
    #     error: Function called without required argument "nodejs_26" …
    #   toplevel forces the package (hermes.nix puts it in home.packages), so
    #   `nixos-rebuild` could not even start.
    #
    #   So the ref is the newest upstream TAG whose nix/lib.nix still takes a
    #   plain `nodejs` argument — a name that says what it is and moves in
    #   reviewable steps, where the bare rev this used to carry read to Renovate
    #   as a digest to be walked forward. Before advancing it, diff that
    #   argument list: a node major we don't have breaks eval system-wide, and
    #   renovate.json disables the bot here for exactly that reason.
    #
    #   Do NOT "fix" this by aliasing the missing nodejs major to an older one:
    #   upstream moved deliberately and the runtime may depend on it. Unpin once
    #   nixpkgs carries the major it wants, or upstream relaxes the requirement.
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.7.30";
      inputs.nixpkgs.follows = "nixpkgs";
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
    #
    # Unpinned as of 5.2.3. It was held at 67720c89 on the theory that upstream's
    # Renovate-recomputed pnpm-deps hash was x86_64-only — the defect airtrail-nix
    # really did have. What the pin was ACTUALLY holding back was
    # patches/base-path-support.patch: 5.2.3 deleted the
    # `Access-Control-Allow-Origin` line its uploads.ts hunk targets, so the patch
    # stopped applying. Fixed upstream in reactive-resume-nix#8 (the hunk is
    # obsolete, not misplaced — it is dropped, not re-anchored).
    #
    # The arch theory was, however, only WRONG AT THE TIME. This comment used to
    # record a measurement that both arches landed on one
    # /nix/store/xck2n5ir…-reactive-resume-pnpm-deps, because fetchPnpmDeps runs
    # `pnpm install --force`, which nixpkgs documents as fetching "all dependencies
    # including ones that aren't meant for our host platform". True through pnpm
    # 11.10.0. 5.2.5 moved package.json's `packageManager` to pnpm@11.18.0, which
    # prunes the store it materialises to the host platform — the two arches now
    # ship different native bindings (@rolldown/binding-linux-x64-gnu vs
    # -arm64-gnu) and hash differently. So the airtrail defect DID eventually
    # arrive here; reactive-resume-nix#10 handles it by selecting the pnpmDeps hash
    # on stdenv.hostPlatform.system. Renovate only ever computes the x86_64 one, so
    # a version bump still needs the aarch64 hash added BY HAND, on aarch64 — a
    # bump that does not is a bump that cannot build on the Pi.
    reactive-resume-nix = {
      url = "github:nSimonFR/reactive-resume-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Gramps Web genealogy — same pattern as reactive-resume-nix / sure-nix.
    # Held at the last rev whose gramps-web-api builds against our pinned
    # nixpkgs. Upstream a3f86d5 bumped gramps-web-api → 3.17.0 (gramps-web v26),
    # which needs gramps>=6.0.4, pillow<12, sifts>=1.1 plus yclade/authlib/
    # gramps-gedcom7/flask-smorest — none satisfied by our nixpkgs — so its
    # pythonRuntimeDepsCheck fails. Unpin once gramps-web-nix is compatible.
    #
    # This is not theoretical: Renovate proposed exactly that bump (#438), it was
    # merged 2026-08-10, and `system.build.toplevel` stopped building —
    #   Checking runtime dependencies for gramps_webapi-3.17.0-py3-none-any.whl
    #     - gramps<6.1.0,>=6.0.4 not satisfied by version 6.0.3
    #     - pillow<12.0.0,>=9.1.0 not satisfied by version 12.2.0
    #     - sifts>=1.1.0 not satisfied by version 1.0.0
    #     - yclade / authlib / gramps-gedcom7 / flask-smorest not installed
    # — so the bump is now disabled in renovate.json rather than left to be
    # re-proposed and re-merged against this warning.
    gramps-web-nix = {
      url = "github:nSimonFR/gramps-web-nix/4e1740a1fdb7cccf3244d3152e26e2ce4dcab027";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # BeaverHabits habit tracker — Python/NiceGUI, packaged via uv2nix. First
    # Python native app here; its flake carries the uv2nix stack itself, so we
    # only pin nixpkgs. See hosts/rpi5/beaverhabits.nix.
    beaverhabits-nix = {
      url = "github:nSimonFR/beaverhabits-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Ryot — self-hosted media & life tracker (IgnisDa/ryot), built from source
    # (container-only upstream, not in nixpkgs). Same pattern as the others.
    # Published at github:nSimonFR/ryot-nix (self-hosted Renovate bumps the version;
    # nSimonFR-ai has push access). Bump with `nix flake lock --update-input ryot-nix`.
    # Heavy Rust/Node compile is built locally on the Pi (no prebuild cache — see the
    # garnix deprecation note in nixConfig below).
    ryot-nix = {
      url = "github:nSimonFR/ryot-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CLIP content filter for Immich Workflows — the sidecar, the WASM plugin and
    # the drainer that used to live in this repo. Extracted so it is installable
    # by anyone (Docker first, Nix second) and testable against a real Immich:
    # 169 unit tests, plus a contract suite that asserts Immich's internal schema
    # and REST routes still match, which is the early warning for an upgrade.
    # Same pattern as sure-nix / airtrail-nix / ryot-nix.
    immich-clip-filter = {
      url = "github:nSimonFR/immich-clip-filter";
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
    # pkgs/agents/rtk.nix builds it with rustPlatform.buildRustPackage and it's exposed
    # as `pkgs.rtk` via pkgs/overlay.nix. Bumping is a 2-step edit:
    #   1. change the tag in the URL below (e.g. v0.42.4 → v0.43.0)
    #   2. bump `version` in pkgs/agents/rtk.nix to match
    # then `sudo nix flake lock --update-input rtk-src` + rebuild.
    rtk-src = {
      url = "github:rtk-ai/rtk/v0.42.4";
      flake = false;
    };

    # ShowMyCards — self-hosted Magic: The Gathering collection manager
    # (showmycards/showmycards). Source-only input (`flake = false`): the
    # prebuilt image is amd64-only, so pkgs/services/showmycards.nix builds it from source
    # (Go backend + SvelteKit frontend) and exposes `pkgs.showmycards` via an
    # overlay. Bump: change the ref here + `version` in pkgs/services/showmycards.nix, then
    # `sudo nix flake lock --update-input showmycards-src` + rebuild.
    #
    # ⚠ PINNED TO A COMMIT, NOT A TAG. v0.3.0 (2026-05-27) is still upstream's
    #   newest release, but Scryfall retired the plain-JSON bulk downloads in late
    #   July 2026 and v0.3.0 cannot ingest the replacement gzipped-JSONL feed —
    #   every scheduled refresh dies with `unsupported protocol scheme ""`. The
    #   fix (38c0019b, PR #155) landed 21 commits after the tag and has never been
    #   released. Go back to a plain tag pin as soon as upstream cuts one that
    #   contains 38c0019b.
    showmycards-src = {
      url = "github:showmycards/showmycards/28a976a61fadca282fea6a15f86172058a933cdc";
      flake = false;
    };

    # tiny-llm-gate: memory-conscious replacement for LiteLLM.
    # Pinned to a tag; bump the ref to roll forward.
    tiny-llm-gate = {
      url = "github:nSimonFR/tiny-llm-gate/v0.9.4";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Cyrus — Linear coding-agent dispatcher (cyrusagents/cyrus). Source-only
    # input (`flake = false`): hosts/rpi5/cyrus.nix vendors it and builds with pnpm
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
      # (hosts/beast/immich-ml.nix) and Immich REQUIRES server==ML version. Derive it
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

      # ── Host facts ────────────────────────────────────────────────────────
      # `hostname` reaches every system AND home-manager config below, but a
      # name alone can't tell a module what a host can *do* — and the two Linux
      # hosts are indistinguishable to `pkgs.stdenv.isDarwin`, which is all a
      # module under home/ used to have to go on. So each row carries a
      # capability set as well. Modules branch on the capability, never on the
      # name, so a fourth host is a row here rather than a new string compare in
      # every module. See docs/adr/0008-host-capabilities-over-hostnames.md.
      hosts = {
        ${nixconfig} = {
          name = nixconfig;
          # Graphical workstation: GUI editors, and the Bitwarden *desktop* app
          # that provides the SSH agent socket home/ssh.nix points at.
          isGraphical = true;
          # Star Citizen launcher config + the two prefix symlinks it writes back
          # through. The Mac is graphical but doesn't run it.
          runsStarCitizen = true;
          # 16K-page kernel — claude-code's vendored ripgrep ships a 4K-page
          # jemalloc and SIGABRTs there. Only the Pi.
          has16KPages = false;
        };
        ${rpiconfig} = {
          name = rpiconfig;
          isGraphical = false;
          runsStarCitizen = false;
          has16KPages = true;
        };
        ${macconfig} = {
          name = macconfig;
          isGraphical = true;
          runsStarCitizen = false;
          has16KPages = false;
        };
      };

      # The argument set every config gets, spelled once instead of seven times.
      # Spelling it out per-site is how `beastHost` came to be referenced by
      # hosts/beast/immich-ml.nix while never being passed to BeAsT — it only survived
      # because the sole reference sits in a `#` comment, where Nix doesn't
      # interpolate. Per-config extras are merged on top at each call site.
      baseArgs = name: {
        inherit
          inputs
          outputs
          username
          telegramChatId
          ;
        hostname = name;
        host = hosts.${name};
      };

      # nixpkgs-unstable for a given system. Four of the five `unstablePkgs`
      # spellings below were byte-identical modulo the system string; the fifth
      # (BeAsT's home-manager config) needs an overlay and keeps its own.
      unstableFor =
        system:
        import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };

      # Systems we build first-party, pure-Python things for. Deliberately
      # includes x86_64 so the script checks can run on beast (or CI) instead of
      # on the 3.9 GB Pi.
      checkSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      devSystems = checkSystems ++ [ "aarch64-darwin" ];

      # This repo's own packages (pkgs/) as one overlay — single source of truth
      # so `pkgs.rtk`, `pkgs.showmycards`, `pkgs.mtg-mcp` and `pkgs.openrgb-lg`
      # resolve identically in NixOS modules (via hosts/rpi5/overlays.nix and
      # hosts/beast/overlays.nix) and in the standalone home-manager configs below.
      # See pkgs/overlay.nix for what does and does not belong in it.
      nicOsOverlay = import ./pkgs/overlay.nix inputs;
    in
    {
      # Exposed so hosts/rpi5/overlays.nix and hosts/beast/overlays.nix pull the same
      # overlay (DRY).
      overlays.nic-os = nicOsOverlay;

      # Run by .github/workflows/nix.yml on every PR. Building nicos-scripts runs
      # its pytest suite (checkPhase), so a broken connector payload fails here
      # instead of at 04:50 on a timer:
      #
      #   nix build .#checks.aarch64-linux.nicos-scripts
      #
      # Prefer that explicit form over bare `nix flake check`, which also forces
      # every other output (the heavy ryot/showmycards/hermes derivations) —
      # expensive on a 3.9 GB Pi.
      checks = nixpkgs.lib.genAttrs checkSystems (system: {
        inherit (self.packages.${system}) nicos-scripts;
      });

      # `nix develop` — python3 + pytest to run the script tests in-tree:
      #   cd hosts/rpi5/scripts/lib && pytest
      # plus shellcheck for the shell scripts under hosts/rpi5/scripts/.
      devShells = nixpkgs.lib.genAttrs devSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              (pkgs.python3.withPackages (ps: [ ps.pytest ]))
              pkgs.shellcheck
            ];
            shellHook = ''
              echo "nic-os dev shell — script tests: (cd hosts/rpi5/scripts/lib && pytest)"
            '';
          };
        }
      );

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
          let
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              overlays = [ nicOsOverlay ];
            };
          in
          {
            inherit (pkgs) rtk;
            # `nix build .#nicos-scripts` — also the flake check (see `checks`).
            inherit (pkgs) nicos-scripts;
          }
        ))
        {
          aarch64-linux.reactive-resume =
            self.nixosConfigurations.${rpiconfig}.config.services.reactive-resume.package;
          # Expose Ryot as a standalone target (`nix build .#ryot`) so its heavy
          # Rust LTO + Node build can be isolated/pinned and optionally pushed to
          # a binary cache (Cachix/attic). Built locally on the Pi by default —
          # there is no prebuild CI cache (garnix is deprecated). See hosts/rpi5/ryot.nix.
          aarch64-linux.ryot =
            self.nixosConfigurations.${rpiconfig}.config.services.ryot.package;
          # ShowMyCards — `nix build .#showmycards` to isolate its Go (cgo) +
          # SvelteKit compile from a full rebuild and validate/pin it first
          # (no prebuild cache). Pulls the exact rpi5 derivation via the overlay.
          aarch64-linux.showmycards =
            self.nixosConfigurations.${rpiconfig}.pkgs.showmycards;
          # FreeReps — `nix build .#freereps` to isolate its Go + Vite/React
          # compile from a full rebuild. Same reasoning as showmycards above:
          # no prebuild cache, and this one is OOM-prone on a 4 GB box because
          # the tailscale dependency tree and a Rollup build land in one
          # derivation. See hosts/rpi5/freereps.nix.
          aarch64-linux.freereps =
            self.nixosConfigurations.${rpiconfig}.pkgs.freereps;
          # Hermes Agent — lean `messaging` variant. Exposed as a standalone
          # target (`nix build .#hermes-messaging`) so its heavy uv2nix Python +
          # npm compile can be validated/isolated on the Pi BEFORE wiring the
          # user service (OOM-prone; no prebuild cache). See hosts/rpi5/hermes/hermes.nix.
          aarch64-linux.hermes-messaging =
            inputs.hermes-agent.packages.aarch64-linux.messaging;
        };

      nixosConfigurations.${nixconfig} = nixpkgs.lib.nixosSystem rec {
        system = "x86_64-linux";
        specialArgs = baseArgs nixconfig // {
          # beast runs the Immich ML worker; version must match the rpi5 server.
          # `beastHost` is its own tailnet name — referenced by hosts/beast/immich-ml.nix
          # and previously not passed here at all.
          inherit immichVersion beastHost;
        };
        modules = [
          ./hosts/beast/configuration.nix
        ];
      };

      nixosConfigurations.${rpiconfig} = inputs.nixos-raspberrypi.lib.nixosSystem {
        # Use our nixpkgs as the base so non-kernel packages hit cache.nixos.org.
        # Kernel/firmware still come from nixos-raspberrypi's overlays (cached on
        # nixos-raspberrypi.cachix.org).
        # This is NOT the same as inputs.nixos-raspberrypi.inputs.nixpkgs.follows (which would
        # break the kernel cache).
        nixpkgs = inputs.nixpkgs;
        specialArgs = baseArgs rpiconfig // {
          inherit (rpi5Params) tailnetFqdn beastOllamaUrl apertureUrl tinyLlmGateUrl beastHost immichVersion;
          nixos-raspberrypi = inputs.nixos-raspberrypi;
          unstablePkgs = unstableFor "aarch64-linux";
        };
        modules = [
          ./hosts/rpi5/overlays.nix
          inputs.ragenix.nixosModules.default
          inputs.home-manager.nixosModules.home-manager
          inputs.sure-nix.nixosModules.sure
          inputs.for-sure.nixosModules.default
          inputs.airtrail-nix.nixosModules.airtrail
          inputs.reactive-resume-nix.nixosModules.reactive-resume
          inputs.gramps-web-nix.nixosModules.gramps-web
          inputs.beaverhabits-nix.nixosModules.beaverhabits
          inputs.ryot-nix.nixosModules.ryot
          inputs.immich-clip-filter.nixosModules.default
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "hm-backup";
              extraSpecialArgs = baseArgs rpiconfig // {
                # tailnetFqdn: home/mcp.nix. apertureUrl + tinyLlmGateUrl:
                # hosts/rpi5/hermes/hermes.nix, which is a home-manager module even
                # though it lives under the host dir (imported via
                # hosts/rpi5/home.nix). beastOllamaUrl has no home-manager consumer
                # and is passed to the system config only.
                inherit (rpi5Params) tailnetFqdn apertureUrl tinyLlmGateUrl;
                devSetup = false;
                unstablePkgs = unstableFor "aarch64-linux";
              };
              users.${username} = {
                imports = [
                  inputs.ragenix.homeManagerModules.default
                  ./home
                  ./hosts/rpi5/home.nix
                ];
              };
            };
          }
          ./hosts/rpi5/configuration.nix
        ];
      };

      darwinConfigurations.${macconfig} = darwin.lib.darwinSystem rec {
        system = "aarch64-darwin";
        specialArgs = baseArgs macconfig;
        modules = [
          ./hosts/nbookpro/configuration.nix
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
            overlays = [ nicOsOverlay ];
          };
          extraSpecialArgs = baseArgs nixconfig // {
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
            ./hosts/beast/home.nix
          ];
        };

        "${username}@${rpiconfig}" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "aarch64-linux";
            config.allowUnfree = true;
            overlays = [ nicOsOverlay ];
          };
          extraSpecialArgs = baseArgs rpiconfig // {
            # Same module set as the NixOS-integrated config above, so the same
            # hermes arguments are required.
            inherit (rpi5Params) tailnetFqdn apertureUrl tinyLlmGateUrl;
            devSetup = false;
            unstablePkgs = unstableFor "aarch64-linux";
          };
          modules = [
            inputs.ragenix.homeManagerModules.default
            ./home
            ./hosts/rpi5/home.nix
          ];
        };

        "${username}@${macconfig}" = home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs {
            system = "aarch64-darwin";
            config.allowUnfree = true;
            overlays = [ nicOsOverlay ];
          };
          extraSpecialArgs = baseArgs macconfig // {
            inherit (rpi5Params) tailnetFqdn;
            devSetup = true;
            unstablePkgs = unstableFor "aarch64-darwin";
          };
          modules = [
            inputs.ragenix.homeManagerModules.default
            ./home
            ./hosts/nbookpro/home.nix
          ];
        };
      };

    };
}
