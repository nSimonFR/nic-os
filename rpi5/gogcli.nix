{
  lib,
  buildGo126Module,
  gogcli-src,
  version ? "0.21.0",
  vendorHash ? "sha256-ElQF27p/kDaRSCwUuWLHV4AJ36ZlNI0OmqemmiJHBkE=",
}:

buildGo126Module {
  pname = "gogcli";
  inherit version vendorHash;

  src = gogcli-src;

  subPackages = [ "cmd/gog" ];

  # nixpkgs has Go 1.26.1; gogcli requires 1.26.2 — trivial patch
  postPatch = ''
    substituteInPlace go.mod --replace-fail 'go 1.26.2' 'go 1.26.1'
  '';

  ldflags = [
    "-s"
    "-w"
  ];

  meta = with lib; {
    description = "Google Suite CLI: Gmail, GCal, GDrive, GContacts";
    homepage = "https://gogcli.sh";
    license = licenses.mit;
    mainProgram = "gog";
  };
}
