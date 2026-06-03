{
  lib,
  buildGo126Module,
  goplaces-src,
  version ? "0.4.3",
  vendorHash ? "sha256-OFTjLtKwYSy4tM+D12mqI28M73YJdG4DyqPkXS7ZKUg=",
}:

# v0.4.3 go.mod requires Go ≥1.25.10; nixpkgs 25.11 default Go (1.25.9)
# is too old. Use buildGo126Module like the sibling gogcli module.
buildGo126Module {
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
