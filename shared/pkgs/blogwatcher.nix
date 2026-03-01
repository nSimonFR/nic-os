{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "blogwatcher";
  version = "0.0.2";

  src = fetchFromGitHub {
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
