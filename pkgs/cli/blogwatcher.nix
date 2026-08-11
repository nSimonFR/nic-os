{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "blogwatcher";
  # renovate: datasource=github-releases depName=Hyaxia/blogwatcher extractVersion=^v(?<version>.+)$
  version = "0.0.3";

  src = fetchFromGitHub {
    # Version in the name so a stale `hash` fails loudly.
    # See .cursor/rules/fixed-output-names.mdc.
    name = "${pname}-${version}-source";
    owner = "Hyaxia";
    repo = "blogwatcher";
    rev = "v${version}";
    hash = "sha256-O9CAEJoSr6fWeznKewvEIHqW6BZiz5LI7gIp6w2SnBc=";
  };

  subPackages = [ "cmd/blogwatcher" ];

  vendorHash = "sha256-TfcMKlr/mdElYLf2zw9iNLJgGVJzMVg97jJm015ClTQ=";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta = with lib; {
    description = "Terminal-based RSS and Atom feed tracker";
    homepage = "https://github.com/Hyaxia/blogwatcher";
    license = licenses.mit;
    maintainers = [ ];
    mainProgram = "blogwatcher";
  };
}
