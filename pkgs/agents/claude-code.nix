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
    version = "2.1.332";
    platforms = {
      # aarch64-darwin — nBookPro
      "darwin-arm64" = {
        binary = "claude.zst";
        checksum = "8a4cbdcb6279039c5584562a75154a818f622476c8e46de1f9ae1cbe40c12859";
      };
      # aarch64-linux — rpi5
      "linux-arm64" = {
        binary = "claude.zst";
        checksum = "b76015ad1663566187a721e5641f6190722c0d2f95bfc35ff42ef4781fae0fa3";
      };
      # x86_64-linux — BeAsT
      "linux-x64" = {
        binary = "claude.zst";
        checksum = "e9f53728e093fb9bea7e9c75094b6cfd7e6a82ee3791efbbf22238d6695f6220";
      };
    };
  };
}
