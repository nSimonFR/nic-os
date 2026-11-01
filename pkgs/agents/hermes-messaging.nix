# Hermes Agent (NousResearch/hermes-agent), its lean `messaging` variant — the
# rpi5 Telegram agent run by hosts/rpi5/hermes/hermes.nix.
#
# Built by upstream's own flake (`hermes-agent` input), not by a derivation
# here: the version is that input's tag in flake.nix, which Renovate bumps.
{ hermes-agent, hermesPkgs }:
hermes-agent.packages.${hermesPkgs.stdenv.hostPlatform.system}.messaging
