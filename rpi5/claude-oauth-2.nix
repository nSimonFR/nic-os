# Keep-warm sidecar for the second Anthropic account used by tiny-llm-gate's
# multi-account failover. Unlike account 1 (the user's daily-driver login,
# kept fresh by claude-remote-control.nix's 24/7 bridge), account 2 is
# gate-only and nothing else touches it interactively, so it only needs the
# generic keep-warm builder — see claude-oauth-keepwarm.nix.
#
# Login is a manual one-time step (OAuth needs a real browser/device flow):
#   CLAUDE_CONFIG_DIR=~/.claude-secondary claude
# Keep this account dedicated to the gate — using it for real interactive
# work doesn't break anything structurally, but stops it being a clean spare.
{ pkgs, username, ... }:
let
  keepWarm = import ./claude-oauth-keepwarm.nix { inherit pkgs username; } {
    suffix = "-2";
    configDir = "/home/${username}/.claude-secondary";
    credentialsFile = "/home/${username}/.claude-secondary/.credentials.json";
    onBootSec = "20min"; # offset from the account-1 timer's 15min
  };
in
keepWarm.nixosConfig
