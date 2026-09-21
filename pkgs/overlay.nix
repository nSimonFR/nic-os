# The repo's own packages, exposed as `pkgs.<name>`.
#
# WHAT BELONGS HERE: a package with MORE THAN ONE consumer. An overlay is how a
# derivation gets a single evaluation shared across hosts, NixOS modules and
# standalone home-manager configs — `pkgs.rtk` resolves to the same store path
# everywhere, and `nix build .#rtk` builds exactly what the system runs.
#
# WHAT DOESN'T: a package used in exactly one place. Those stay
# `pkgs.callPackage ../pkgs/<name>.nix { }` at their single use site — an
# overlay entry would add a name to every host's `pkgs` for no gain. Move one
# here the moment a second consumer appears.
#
# Entries are lazy, so listing a package here costs nothing on a host that
# never references it (openrgb-lg is x86-only, showmycards is built on aarch64).
#
# Applied by hosts/rpi5/overlays.nix, hosts/beast/overlays.nix, and the homeConfigurations
# in flake.nix — all via `outputs.overlays.nic-os`.
inputs: final: _prev: {
  # RTK (Rust Token Killer) — built from the rtk-src flake input.
  # Consumers: hosts/rpi5/cyrus.nix, home/, and `nix build .#rtk`.
  rtk = final.callPackage ./agents/rtk.nix { rtk-src = inputs.rtk-src; };

  # ShowMyCards (MTG collection manager) — built from the showmycards-src flake
  # input; the prebuilt upstream image is amd64-only.
  # Consumers: hosts/rpi5/showmycards.nix and `nix build .#showmycards`.
  showmycards = final.callPackage ./services/showmycards.nix {
    showmycards-src = inputs.showmycards-src;
    # backend/go.mod requires `go 1.26.3` and a pure build can't fetch a
    # toolchain (no network in the sandbox), so pass one that already
    # satisfies it: the default `go` is 1.25.10, too old. go_1_26 is
    # 1.26.4 here, matching upstream's golang:1.26-alpine build image.
    go = final.go_1_26;
  };

  # mtg-mcp — MCP server for Magic: The Gathering / Commander.
  # Consumers: hosts/rpi5/hermes/hermes.nix (the Hermes agent) and home/claude-mtg.nix
  # (the Mac's `claude-mtg` CLI). Both used to callPackage it independently,
  # which evaluated the derivation twice with no single source of truth.
  mtg-mcp = final.callPackage ./agents/mtg-mcp.nix { };

  # FreeReps (self-hosted Apple Health server) — built from source; upstream
  # publishes only a docker-compose stack.
  # Consumers: hosts/rpi5/freereps.nix (the service) and
  # hosts/rpi5/hermes/hermes.nix (the `-mcp` stdio server), plus
  # `nix build .#freereps`.
  freereps = final.callPackage ./services/freereps.nix { };

  # nicos-scripts — this repo's own Python: one package holding the shared
  # library plus a console script per unit (bin/steam-to-ryot, bin/homepage-stats,
  # …), with its pytest suite in checkPhase.
  # Consumers: eleven rpi5 units (ryot-connectors, papra, moxfield-sync,
  # travel-cal-sync, homepage, claude-remote-control, claude-notify-aggregator,
  # scale-bridge), home/claude.nix's memory-sync hook, and
  # `nix build .#nicos-scripts` — which is also the flake check.
  nicos-scripts = final.callPackage ./services/nicos-scripts.nix { };

  # OpenRGB 1.0rc2 — the first build with working LG monitor support.
  # Consumers: hosts/beast/rgb/openrgb-lg.nix (systemPackages) and
  # hosts/beast/configuration.nix (services.hardware.openrgb.package).
  openrgb-lg = final.callPackage ./rgb/openrgb-lg.nix { };
}
