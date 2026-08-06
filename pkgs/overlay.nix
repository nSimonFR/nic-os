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
# Applied by rpi5/overlays.nix, nixos/overlays.nix, and the homeConfigurations
# in flake.nix — all via `outputs.overlays.nic-os`.
inputs: final: _prev: {
  # RTK (Rust Token Killer) — built from the rtk-src flake input.
  # Consumers: rpi5/cyrus.nix, home/, and `nix build .#rtk`.
  rtk = final.callPackage ./rtk.nix { rtk-src = inputs.rtk-src; };

  # ShowMyCards (MTG collection manager) — built from the showmycards-src flake
  # input; the prebuilt upstream image is amd64-only.
  # Consumers: rpi5/showmycards.nix and `nix build .#showmycards`.
  showmycards = final.callPackage ./showmycards.nix {
    showmycards-src = inputs.showmycards-src;
    # backend/go.mod requires `go 1.26.3` and a pure build can't fetch a
    # toolchain (no network in the sandbox), so pass one that already
    # satisfies it: the default `go` is 1.25.10, too old. go_1_26 is
    # 1.26.4 here, matching upstream's golang:1.26-alpine build image.
    go = final.go_1_26;
  };

  # mtg-mcp — MCP server for Magic: The Gathering / Commander.
  # Consumers: rpi5/hermes/hermes.nix (the Hermes agent) and home/claude-mtg.nix
  # (the Mac's `claude-mtg` CLI). Both used to callPackage it independently,
  # which evaluated the derivation twice with no single source of truth.
  mtg-mcp = final.callPackage ./mtg-mcp.nix { };

  # OpenRGB 1.0rc2 — the first build with working LG monitor support.
  # Consumers: nixos/rgb/openrgb-lg.nix (systemPackages) and
  # nixos/configuration.nix (services.hardware.openrgb.package).
  openrgb-lg = final.callPackage ./openrgb-lg.nix { };
}
