# no-renovate: the version is the hermes-agent flake input.
# Hermes Agent (NousResearch/hermes-agent), its lean `messaging` variant — the
# rpi5 Telegram agent run by hosts/rpi5/agents/hermes/hermes.nix.
#
# Built by upstream's own flake (`hermes-agent` input), not by a derivation
# here: the version is that input's tag in flake.nix, which Renovate bumps.
# (Its patchelf override for NixOS/patchelf#674 went with the 2026-11 unstable
# bump: nixpkgs reverted patchelf 0.19.2 -> 0.15.2, which predates that bug.)
{
  hermes-agent,
  hermesPkgs,
}:
hermes-agent.packages.${hermesPkgs.stdenv.hostPlatform.system}.messaging
