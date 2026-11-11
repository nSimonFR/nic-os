{
  lib,
  pkgs,
  config,
  unstablePkgs,
  ...
}:
let
  # Keep this in lockstep with the atuin CLI on PATH (home/packages.nix uses
  # unstablePkgs.atuin). If the daemon and the client diverge, the client talks
  # to a stale daemon binary over the socket and sync silently lapses.
  atuinBin = "${unstablePkgs.atuin}/bin/atuin";
  dataDir = "${config.home.homeDirectory}/.local/share/atuin";

  # launchd's KeepAlive can only relaunch a daemon it started — it cannot adopt
  # one it didn't. If an orphaned atuin daemon (e.g. one left over from before
  # this agent existed, or surviving an atuin version bump) already holds the
  # pidfile lock + socket, `atuin daemon start` exits on the busy lock (18.16.1
  # takes the `force = false` path and never probes/stops the holder), so launchd
  # just crash-loops while clients keep talking to the stale daemon. Adopt first:
  # stop whatever currently holds the pidfile, clear the stale socket, then exec
  # the daemon so launchd tracks the new process. On a normal (re)start the
  # recorded pid is already dead, so nothing is killed.
  atuinDaemonStart = pkgs.writeShellScript "atuin-daemon-start" ''
    set -u
    export PATH="${pkgs.coreutils}/bin:$PATH"
    pidfile="${dataDir}/atuin-daemon.pid"
    if [ -r "$pidfile" ]; then
      oldpid="$(head -n1 "$pidfile" 2>/dev/null || true)"
      case "$oldpid" in
        "" | *[!0-9]*) ;; # absent or not a bare pid — ignore
        *)
          if kill -0 "$oldpid" 2>/dev/null; then
            kill "$oldpid" 2>/dev/null || true
            n=0
            while kill -0 "$oldpid" 2>/dev/null && [ "$n" -lt 10 ]; do
              sleep 0.5
              n=$((n + 1))
            done
          fi
          ;;
      esac
    fi
    rm -f "${dataDir}/atuin.sock"
    exec ${atuinBin} daemon start
  '';
in
{
  # Linux runs daemonless: the daemon held ~165 MB RSS on rpi5 (2026-11-11)
  # for no feature used there, while `history end` already writes the record
  # store and syncs every sync_frequency (5m), at ~90 MB for ~3 s.
  # macOS keeps the daemon under launchd below.
  xdg.configFile."atuin/config.toml".text =
    let
      toml = builtins.readFile ./dotfiles/atuin.toml;
      on = "daemon.enabled = true";
    in
    assert lib.hasInfix on toml;
    if pkgs.stdenv.isLinux then
      builtins.replaceStrings [ on ] [ "daemon.enabled = false" ] toml
    else
      toml;

  # launchd opens StandardOutPath/StandardErrorPath before exec'ing the program
  # and will NOT create a missing parent directory, so on a fresh profile (or
  # after the atuin data dir is wiped) bootstrap would fail with an I/O error
  # and the daemon would never start. Guarantee the dir exists before the
  # launchd agents are (re)bootstrapped.
  home.activation = lib.mkIf pkgs.stdenv.isDarwin {
    atuinDataDir = lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
      run mkdir -p "${dataDir}"
    '';
  };

  launchd.agents.atuin-daemon = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ "${atuinDaemonStart}" ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${dataDir}/daemon.out.log";
      StandardErrorPath = "${dataDir}/daemon.err.log";
    };
  };
}
