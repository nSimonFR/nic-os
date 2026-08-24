# DeepSeek Harness (`dsh`) — DeepSeek's open-source agent harness, where every
# capability is a Cordis plugin. Sits beside pi rather than replacing it: dsh
# is 0.1.1-rc and its README promises compatibility-breaking changes.
#
# dsh ships no TUI (the package was deleted upstream on 2026-08-04), so the
# interactive surface is a Web UI — run as a tailnet service by
# hosts/rpi5/dsh.nix. What this module gives every host is the binary itself
# (`dsh --profile headless "…"` for one-shot work) plus the config both
# surfaces read out of ~/.dsh.
{
  pkgs,
  lib,
  inputs,
  ...
}:
{
  home.packages = [ (import ./package.nix { inherit pkgs lib inputs; }) ];

  # The Aperture provider + default model. See the file's own header for the
  # patch grammar and why settings.yaml is not managed here.
  home.file.".dsh/cordis.patch.yml".source = ./cordis.patch.yml;

  # Skills reach ~/.dsh/skills through home/claude.nix's shared skill lineage —
  # dsh-skill-filesystem scans <dshHome>/skills for <name>/SKILL.md bundles,
  # which is exactly what shared/skill-tree.nix already emits.

  # NOTE: ~/.dsh/settings.yaml, ~/.dsh/.credentials.yaml and ~/.dsh/profiles/
  # are intentionally NOT Nix-managed. The Web UI writes the first two, and the
  # launcher auto-initializes and heals the third on every start — a read-only
  # store symlink would break all three.
}
