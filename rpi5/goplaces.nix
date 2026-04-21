{
  lib,
  buildGoModule,
  goplaces-src,
  version ? "0.3.0",
  vendorHash ? "sha256-OFTjLtKwYSy4tM+D12mqI28M73YJdG4DyqPkXS7ZKUg=",
}:

buildGoModule {
  pname = "goplaces";
  inherit version vendorHash;

  src = goplaces-src;

  subPackages = [ "cmd/goplaces" ];

  ldflags = [
    "-s"
    "-w"
  ];

  meta = with lib; {
    description = "Modern Google Places CLI in Go";
    homepage = "https://github.com/steipete/goplaces";
    license = licenses.mit;
    mainProgram = "goplaces";
  };
}
