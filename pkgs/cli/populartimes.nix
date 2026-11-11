{ pkgs, python3 }:

pkgs.writeShellApplication {
  name = "populartimes-query";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${python3}/bin/python3 -I ${../../hosts/rpi5/agents/hermes/skills/populartimes/scripts/query.py} "$@"
  '';
  meta = {
    description = "Google popular times (live + weekly) for a place, via SerpApi";
    mainProgram = "populartimes-query";
  };
}
