# Entire Brain for Trusk: an hourly pass distills new sessions in every Trusk
# clone (scripts/entire-brain-trusk.sh), all in one "trusk" workspace. Nothing
# is written into the trusk-official repos; agents learn about Brain from the
# private TRUSK/CLAUDE.md.
{ config, pkgs, ... }:
let
  entire = pkgs.callPackage ../../pkgs/cli/entire.nix { };
  pass = pkgs.writeShellApplication {
    name = "entire-brain-trusk";
    runtimeInputs = [ entire pkgs.git pkgs.findutils ];
    # $w is empty or one flag; quoting it would pass an empty argument.
    excludeShellChecks = [ "SC2086" ];
    text = builtins.readFile ./scripts/entire-brain-trusk.sh;
  };
  logs = "${config.home.homeDirectory}/Library/Logs/entire-brain-trusk.log";
in
{
  home.packages = [ entire ];

  launchd.agents.entire-brain-trusk = {
    enable = true;
    config = {
      ProgramArguments = [ "${pass}/bin/entire-brain-trusk" ];
      StartInterval = 3600;
      LowPriorityIO = true;
      ProcessType = "Background";
      # The distill step runs claude from the user profile.
      EnvironmentVariables.PATH = "/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin";
      StandardOutPath = logs;
      StandardErrorPath = logs;
    };
  };
}
