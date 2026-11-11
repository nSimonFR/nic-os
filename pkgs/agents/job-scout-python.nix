# Python for the job-offer collectors that run as Hermes cron pre-run scripts
# (`hermes cron … --script`): job-scout's connectors need JobSpy, pandas,
# BeautifulSoup and markdownify. Exposed as `job-scout-python` so the scripts
# (deployed from the private job-scout repo, not from here) call a stable path
# instead of a pip venv, whose numpy/pandas wheels need nix-ld on NixOS.
#
# nixpkgs ships JobSpy 1.1.82; 1.4.1 adds the HelloWork scraper and swaps
# tls-client for curl_cffi, so the source is overridden from PyPI.
{ python3, writeShellScriptBin }:
let
  jobspy = python3.pkgs.jobspy.overridePythonAttrs (_: rec {
    version = "1.4.1";
    src = python3.pkgs.fetchPypi {
      pname = "python_jobspy";
      inherit version;
      sha256 = "1vwq3912mk43jim5cjli2d57mbwyvn376841yrg4hq2g5q8969k0";
    };
    pythonRelaxDeps = true;
    dependencies = with python3.pkgs; [
      beautifulsoup4
      curl-cffi
      markdownify
      pandas
      pydantic
      requests
    ];
  });
  env = python3.withPackages (ps: [
    jobspy
    ps.beautifulsoup4
    ps.markdownify
    ps.requests
  ]);
in
writeShellScriptBin "job-scout-python" ''exec ${env}/bin/python3 "$@"''
