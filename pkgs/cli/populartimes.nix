{ lib, pkgs, python3, python3Packages }:

let
  library = python3Packages.buildPythonPackage {
    pname = "populartimes";
    version = "2.0";
    format = "setuptools";
    src = pkgs.fetchFromGitHub {
      owner = "m-wrzr";
      repo = "populartimes";
      rev = "989f66b63dd1b6a144c5ad4a7c3a200f7f8649ee";
      hash = "sha256-wuiLTcPgPCIsXPuyuUvxv0/Bus6B0x1cCd7U01ramFY=";
    };
    postPatch = ''
      substituteInPlace setup.py \
        --replace-fail 'setup_requires=["pytest-runner", ],' "" \
        --replace-fail 'tests_require=["pytest", ],' ""
    '';
    propagatedBuildInputs = with python3Packages; [ requests geopy urllib3 ];
    pythonRelaxDeps = [ "urllib3" ];
    doCheck = false;
    meta = {
      description = "Access Google Maps popular times data";
      homepage = "https://github.com/m-wrzr/populartimes";
      license = lib.licenses.mit;
    };
  };
  pythonEnv = python3.withPackages (_: [ library ]);
in
pkgs.writeShellApplication {
  name = "populartimes-query";
  runtimeInputs = [ pythonEnv ];
  text = ''
    exec ${pythonEnv}/bin/python ${../../hosts/rpi5/hermes/skills/populartimes/scripts/query.py} "$@"
  '';
  meta = {
    description = "Query Google Maps popular-times data by Place ID";
    mainProgram = "populartimes-query";
  };
}
