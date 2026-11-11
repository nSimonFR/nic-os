# A mautrix bridgev2 bridge nixpkgs does not ship (or ships as the retired
# Python one). Every bridgev2 repo has the same layout: cmd/mautrix-<repo>.
# goolm, not libolm: nixpkgs marks olm insecure, and the bridged rooms here are
# unencrypted anyway (hosts/rpi5/messaging/bridges.nix).
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  repo,
  tag,
  hash,
  vendorHash,
}:
buildGoModule {
  pname = "mautrix-${repo}";
  version = lib.removePrefix "v" tag;

  src = fetchFromGitHub {
    owner = "mautrix";
    inherit repo tag hash;
  };

  inherit vendorHash;
  subPackages = [ "cmd/mautrix-${repo}" ];
  tags = [ "goolm" ];
  ldflags = [
    "-s"
    "-w"
    "-X"
    "main.Tag=${tag}"
  ];

  meta = {
    description = "Matrix-${repo} puppeting bridge";
    homepage = "https://github.com/mautrix/${repo}";
    license = lib.licenses.agpl3Only;
    mainProgram = "mautrix-${repo}";
  };
}
