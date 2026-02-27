{
  nixpkgs,
  system,
}:
let
  pkgs = import nixpkgs { inherit system; };
  skillsRoot = ./openclaw-documents/skills;
  skillEntries = builtins.readDir skillsRoot;
  skillDirs = builtins.filter (name: skillEntries.${name} == "directory")
    (builtins.attrNames skillEntries);
  skillPaths = map (name: skillsRoot + "/${name}") skillDirs;
in
{
  name = "nClaw";
  skills = skillPaths;
  packages = [ pkgs.nodejs_22 ];
  needs = {
    stateDirs = [ ".config/nclaw" ];
    requiredEnv = [ ];
  };
}
