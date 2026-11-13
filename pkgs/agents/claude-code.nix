# claude-code, pinned ahead of nixpkgs.
#
# The server gates models on the client version: 2.1.278 answers
# `--model claude-opus-5-5` with `400 … version 2.1.280 or newer is required`,
# so a settings-only switch to Opus 5.5 does not exist. On 2.1.280 the `opus`
# alias itself resolves to claude-opus-5-5.
#
# nixpkgs' claude-code reads `version` and the per-platform checksum out of
# `manifest` (default: its own manifest.zst.json), and nothing else — so an
# attrset here replaces the whole file. It stays a Nix literal rather than a
# vendored JSON because Renovate's custom manager only reads pkgs/**/*.nix, and
# importing a fetched manifest would need import-from-derivation.
#
# Checksums come from upstream, they are not computed here:
#   https://downloads.claude.ai/claude-code-releases/<version>/manifest.zst.json
# scripts/nix-fix-hashes.py checks them against that URL and `--write`s the fix.
#
# Only the three platforms this repo builds. A fourth fails at eval naming the
# missing key, which is the right time to find out.
{ claude-code }:

claude-code.override {
  manifest = {
    # renovate: datasource=npm depName=@anthropic-ai/claude-code
    version = "2.1.325";
    platforms = {
      # aarch64-darwin — nBookPro
      "darwin-arm64" = {
        binary = "claude.zst";
        checksum = "5117df01bb8150ced024d8944a9706034e0c9bf6e28ee527b8d7735397aca6db";
      };
      # aarch64-linux — rpi5
      "linux-arm64" = {
        binary = "claude.zst";
        checksum = "9e0304bfa6890a8badad29f40061f90a2a6fd704d9d47b44efc10ab74184a0ee";
      };
      # x86_64-linux — BeAsT
      "linux-x64" = {
        binary = "claude.zst";
        checksum = "00b1b977bcc3f32eb69129f0ac3277aafb1aecbfb87c17c0af53806832ed436a";
      };
    };
  };
}
