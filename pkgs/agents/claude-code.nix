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
    version = "2.1.283";
    platforms = {
      # aarch64-darwin — nBookPro
      "darwin-arm64" = {
        binary = "claude.zst";
        checksum = "485d6883c023368800626e0d1f2e4382c3e1bdc760fae12cb2f6e3054f218eec";
      };
      # aarch64-linux — rpi5
      "linux-arm64" = {
        binary = "claude.zst";
        checksum = "7ff80952f5cf74fa593432ec19fc7bef1b4461b365092fe2b6c6060d4fbad1ec";
      };
      # x86_64-linux — BeAsT
      "linux-x64" = {
        binary = "claude.zst";
        checksum = "94345861e88be3d67a8393494f98f5b1c67604c14ccd4ef3c7a51e3643fa25eb";
      };
    };
  };
}
