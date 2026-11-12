# holographic — Hermes' local fact-store memory provider (SQLite + FTS5). Bundled
# with Hermes until v0.22, which moved it to the plugin catalog.
#
# no-renovate: the pin is the sha Hermes' catalog reviewed
# (plugin-catalog/holographic.yaml at the hermes-agent tag), not the plugin's
# latest. Re-read that file when Renovate bumps hermes-agent.
{ fetchFromGitHub }:
let
  version = "0.17.4";
in
fetchFromGitHub {
  name = "hermes-holographic-${version}-source";
  owner = "itpartypattaya";
  repo = "hermes-plugin-holographic";
  rev = "827c639e3cf38b17e9b5c1b6a4ef2ef7880ae953";
  hash = "sha256-XeT6wjwQ8IU3taTV6tsEPGpkmoAanVVkTtp/ub323A8=";
}
