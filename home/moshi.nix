{
  pkgs,
  lib,
  config,
  ...
}:
# Moshi (getmoshi.app) — the iOS client that shows agent activity, answers
# permission prompts and attaches to the multiplexer over SSH/mosh.
#
# Three pieces, none of which live here on their own:
#   - the binary        → hosts/nbookpro/components/homebrew.nix (`moshi-hook`)
#   - the agent hooks   → home/dotfiles/claude-settings.json (vendored, see its
#                         `_comment_moshi`)
#   - the daemon        → this file
#
# Darwin-only: upstream ships a signed release tarball per platform, and only
# the macOS one is packaged (as a brew formula). The Linux hosts get nothing,
# which is why the vendored hooks are written to fail open there.
let
  moshiHook = "/opt/homebrew/bin/moshi-hook";

  # Fixed by moshi-hook itself — socket, log and pairing state all live here.
  stateDir = "${config.home.homeDirectory}/Library/Application Support/Moshi";
in
{
  # `brew services start moshi-hook` is the documented way to run this, and is
  # deliberately NOT used: it writes ~/Library/LaunchAgents/homebrew.mxcl.* by
  # hand, outside nix. This agent is the same daemon under home-manager, so
  # never start the brew service too — both bind the same socket.
  #
  # PATH matters: the daemon shells out to the multiplexer (herdr, tmux) for
  # session attach and to git for the diff viewer, and a launchd agent inherits
  # none of the login shell's PATH.
  launchd.agents.moshi-hook = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    config = {
      ProgramArguments = [
        moshiHook
        "serve"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${stateDir}/serve.out.log";
      StandardErrorPath = "${stateDir}/serve.err.log";
      EnvironmentVariables = {
        PATH = lib.concatStringsSep ":" [
          "/opt/homebrew/bin"
          "${config.home.profileDirectory}/bin"
          "/usr/bin"
          "/bin"
          "/usr/sbin"
          "/sbin"
        ];
      };
    };
  };

  # launchd opens StandardOutPath/StandardErrorPath before exec'ing and will not
  # create a missing parent, so the agent would never start on a host that has
  # not run moshi-hook by hand yet (same failure as atuin's data dir).
  home.activation = lib.mkIf pkgs.stdenv.isDarwin {
    moshiStateDir = lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
      run mkdir -p "${stateDir}"
    '';
  };
}
