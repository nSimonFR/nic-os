# mautrix-imessage, the Mac-side bridge (reads Messages' chat.db, sends through
# AppleScript). No release is ever published, so it is built from a pinned commit.
# This mautrix-go vintage links libolm through cgo and has no goolm tag; nixpkgs'
# olm is flagged insecure, and the bridge never uses it (encryption is off).
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  olm,
}:
let
  # renovate: datasource=git-refs depName=https://github.com/mautrix/imessage branch=master
  rev = "300ba6d0e5566d1f841d42ee1555779a9b6fa4be";
in
buildGoModule {
  pname = "mautrix-imessage";
  version = "0-unstable-2026-05-14";

  src = fetchFromGitHub {
    name = "mautrix-imessage-${rev}-source";
    owner = "mautrix";
    repo = "imessage";
    inherit rev;
    hash = "sha256-qKSb4/kktqNHyOKOOLDrAqV+GZ5StU3lGUc3/90CE+c=";
  };
  vendorHash = "sha256-xTzxL4pk6tmWcEhd0bbdwP70hEqNDjB/xahLWY5nRKQ=";

  buildInputs = [
    (olm.overrideAttrs (o: {
      meta = o.meta // {
        knownVulnerabilities = [ ];
      };
    }))
  ];
  doCheck = false;

  meta = {
    description = "Matrix-iMessage puppeting bridge (Mac connector)";
    homepage = "https://github.com/mautrix/imessage";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.darwin;
    mainProgram = "mautrix-imessage";
  };
}
