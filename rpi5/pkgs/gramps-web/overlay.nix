# Overlay: native Gramps Web packages, vendored from nixpkgs PR #417806
# (TomaSajt: "gramps-web: init at 25.6.0; python3Packages.gramps-web-api: init
# at 3.2.0"). That PR is a stalled draft on an old nixpkgs base whose fetchurl
# is incompatible with the current Nix/curl, so it can't be consumed as a flake
# input — instead we carry the derivations here and build them against our own
# nixpkgs 25.11. The fetches are content-hashed, so they're version-stable.
#
# Adds to python3Packages: gramps (6.0.3, importable library — distinct from the
# top-level `gramps` desktop app), gramps-ql, object-ql, sifts, gramps-web-api.
# Plus top-level `gramps-web` (the grampsjs frontend, → $out/share/gramps-web/static).
#
# Deviations from upstream PR:
#   - AI extras (accelerate/openai/sentence-transformers → PyTorch) dropped from
#     gramps-web-api: far too heavy for the RPi5 (see its default.nix).
#   - doCheck disabled on the Python packages: the upstream test suites are slow
#     and occasionally network/model-dependent, and painful on aarch64 under the
#     RPi5's memory limits. pythonImportsCheck still runs as a smoke test.
final: prev:
let
  noCheck = pkg: pkg.overridePythonAttrs (_: {
    doCheck = false;
    doInstallCheck = false;
  });

  grampsOverrides = pyfinal: _pyprev: {
    gramps         = noCheck (pyfinal.callPackage ./gramps { });
    gramps-ql      = noCheck (pyfinal.callPackage ./gramps-ql.nix { });
    object-ql      = noCheck (pyfinal.callPackage ./object-ql.nix { });
    sifts          = noCheck (pyfinal.callPackage ./sifts.nix { });
    gramps-web-api = noCheck (pyfinal.callPackage ./gramps-web-api { });
  };
in
{
  python3 = prev.python3.override (old: {
    packageOverrides = prev.lib.composeExtensions
      (old.packageOverrides or (_: _: { }))
      grampsOverrides;
  });
  python3Packages = final.python3.pkgs;

  gramps-web = final.callPackage ./frontend.nix { };
}
