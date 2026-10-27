# Entire Brain + Graph for Trusk. `entire brain setup --workspace trusk` (run per
# repo) installs Entire's own watcher, io.entire.brain-watch.*: it distills every
# Trusk repo hourly with claude-code/sonnet (plan in ~/.local/state/entire). It
# execs ~/.nix-profile/bin/entire-brain, so the bundle must stay in the profile.
# Agents get the guide from the private TRUSK/AGENTS.md (home/claude.nix).
{ pkgs, ... }:
{
  home.packages = [ (pkgs.callPackage ../../pkgs/cli/entire.nix { }) ];
}
