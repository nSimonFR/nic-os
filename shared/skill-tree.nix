# The skill seam — one builder for every agent surface.
#
#   skill    a DIRECTORY: SKILL.md plus whatever it needs at runtime (assets/,
#            references/, scripts/). The directory is the unit, never just the
#            SKILL.md — see the commit that introduced this.
#   lineage  a directory whose immediate children are skills. Four exist:
#            shared/skills, shared/mtg-skills, rpi5/hermes/skills,
#            home/claude-skills.
#   surface  an agent installation with its own skills dir.
#
# `prefix` nests a lineage under a subdirectory; only Hermes uses it (mtg/).
{ lib }:
let
  lineageEntries =
    { source, prefix ? "" }:
    map (name: {
      inherit name prefix;
      path = if prefix == "" then name else "${prefix}/${name}";
      skill = "${source}/${name}";
    }) (lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir source)));

  # Later lineages win on a name collision, matching hermes.nix's old `cp -rf`.
  entries = lib.concatMap lineageEntries;
in
{
  # Runtime dir names a lineage list contributes, prefixes included. Lets
  # hermes-skill-promote ask what the repo seeds instead of re-deriving it.
  names =
    lineages:
    lib.unique (
      map (e: e.name) (entries lineages) ++ lib.filter (p: p != "") (map (l: l.prefix or "") lineages)
    );

  # One home.file symlink per skill dir. Per-skill, not one for the whole tree,
  # so the surface's skills dir stays a real directory and plugin/unmanaged
  # skills still work beside the versioned ones.
  homeFiles =
    { targets, lineages }:
    lib.listToAttrs (
      lib.concatMap (
        e: map (t: lib.nameValuePair "${t}/${e.path}" { source = e.skill; }) targets
      ) (entries lineages)
    );

  # Merged store dir, for surfaces that copy rather than symlink — Hermes rsyncs
  # it into $HERMES_HOME so every skill's realpath stays inside HOME.
  tree =
    { pkgs, name ? "skill-tree", lineages }:
    pkgs.runCommand name { } (
      lib.concatMapStrings (e: ''
        mkdir -p "$out/$(dirname ${lib.escapeShellArg e.path})"
        rm -rf "$out/${e.path}"
        cp -RL ${e.skill} "$out/${e.path}"
      '') (entries lineages)
      + ''chmod -R u+w "$out"''
    );
}
