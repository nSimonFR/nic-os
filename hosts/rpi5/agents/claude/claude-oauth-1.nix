# Account 1's OAuth keep-warm: refresh timer + extract to /run/claude-oauth/token,
# read by the gate/Aperture Anthropic pool.
#
# ~/.claude-rc owns the tokens (ADR 0007): `claude` replaces credentials.json on
# refresh, so the two dirs diverge and the extractor picks the live one.
{ pkgs, username, ... }:
let
  configDir = "/home/${username}/.claude-rc";
  keepWarm = import ./claude-oauth-keepwarm.nix { inherit pkgs username; } {
    inherit configDir;
    credentialsFiles = [
      "${configDir}/.credentials.json"
      "/home/${username}/.claude/.credentials.json"
    ];
  };
in
keepWarm.nixosConfig
