# RTK (Rust Token Killer) — shared home-manager wiring.
#
# Puts `rtk` on the user shell PATH and wires the two user-facing agents that
# read config from $HOME:
#   - Pi    : transparent rewriting via a `tool_call` extension (delegates to
#             `rtk rewrite`). Mirrors home/pi-coding-agent/extensions/*.ts.
#   - Codex : instruction-tier only (Codex has no command-interception hook) —
#             a global ~/.codex/AGENTS.md telling the model to prefix shell
#             commands with `rtk`.
#
# Claude Code's hook is wired separately in home/dotfiles/claude-settings.json
# (a PreToolUse Bash hook → `rtk hook claude`), and picoclaw/cyrus are wired in
# their own NixOS modules. They all rely on `rtk` being on PATH, which this
# module's home.packages entry provides for the interactive user.
#
# `pkgs.rtk` is supplied by the rtk overlay (flake.nix outputs.overlays.rtk),
# applied to every home-manager pkgs set (standalone configs + the rpi5
# NixOS-integrated generation via rpi5/overlays.nix).
{ pkgs, ... }:
{
  home.packages = [ pkgs.rtk ];

  home.file.".pi/agent/extensions/rtk.ts".source = ./pi-rtk.ts;

  home.file.".codex/AGENTS.md".source = ./codex-AGENTS.md;
}
