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
    version = "2.1.291";
    platforms = {
      # aarch64-darwin — nBookPro
      "darwin-arm64" = {
        binary = "claude.zst";
        checksum = "2f750a99ce662a1f5d586a88e1a13463c9e88ae9e55a492878a82e46685414f5";
      };
      # aarch64-linux — rpi5
      "linux-arm64" = {
        binary = "claude.zst";
        checksum = "1516c691c7ca10ca0a09d00160c006dfdb1f44263c928e6e4360363717de03f6";
      };
      # x86_64-linux — BeAsT
      "linux-x64" = {
        binary = "claude.zst";
        checksum = "659b2a4f57441eae2bad4e1ee67f93c26fe630863683463f48c7000ebeda8372";
      };
    };
  };
}
