{ config, lib, pkgs, inputs, ... }:

{
  # The user account that owns ~/.claude/.credentials.json and
  # ~/.codex/sessions is `nsimon`. gleaner.service runs as that user so
  # `gleaner snapshot` can read both at zero token cost.
  services.gleaner = {
    enable     = true;
    user       = "nsimon";
    configFile = ./gleaner.config.yaml;
    timer.onUnitActiveSec = "10min";
    timer.persistent = true;
  };

  # Expose `gleaner` on the system PATH so the user can run `gleaner
  # snapshot` from any shell without remembering the nix store path.
  environment.systemPackages = [
    inputs.gleaner.packages.${pkgs.system}.default
  ];
}
