{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "blogwatcher";
  # renovate: datasource=github-releases depName=Hyaxia/blogwatcher extractVersion=^v(?<version>.+)$
  version = "0.0.4";

  src = fetchFromGitHub {
    # Version in the name so a stale `hash` fails loudly.
    # See .cursor/rules/fixed-output-names.mdc.
    name = "${pname}-${version}-source";
    owner = "Hyaxia";
    repo = "blogwatcher";
    rev = "v${version}";
    hash = "sha256-Zd3Pqv2gCB6EwSR5uh88aHEXtI49mmXSbKuVDf2vAGA=";
  };

  subPackages = [ "cmd/blogwatcher" ];

  vendorHash = "sha256-TfcMKlr/mdElYLf2zw9iNLJgGVJzMVg97jJm015ClTQ=";

  ldflags = [
    "-s"
    "-w"
    # The version string lives in internal/version, not in main — stamping
    # `main.version` set a symbol nothing reads, so every build shipped the
    # package default and `blogwatcher --version` printed "dev" for 0.0.2 and
    # 0.0.3 alike. That is the one check that tells you which build is live.
    "-X github.com/Hyaxia/blogwatcher/internal/version.Version=${version}"
  ];

  meta = with lib; {
    description = "Terminal-based RSS and Atom feed tracker";
    homepage = "https://github.com/Hyaxia/blogwatcher";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "blogwatcher";
  };
}
