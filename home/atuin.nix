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
  # Keep atuin's sync daemon (`daemon.enabled = true` in dotfiles/atuin.toml)
  # alive headlessly so background hooks (e.g. the Claude Code Bash PostToolUse
  # hook in home/scripts/claude-bash-history.sh) and history written outside an
  # interactive shell still sync to api.atuin.sh. `atuin init zsh` does NOT
  # start the daemon on its own, so without a real process supervisor the daemon
  # dies — or, worse, lingers on a stale binary after an atuin version bump —
  # and sync quietly stops. Each platform gets its native supervisor; the
  # supervisor restarts the daemon on the new binary whenever atuinBin changes,
  # which closes the version-skew gap.
  #
  # 2026-06-15: the macOS box had been running an orphaned 18.15.2 daemon since
  # April because only the Linux (systemd) path existed — darwin had no
  # equivalent and home-manager silently ignored the systemd block here. Hence
  # the launchd agent below.

  systemd.user.services = lib.mkIf pkgs.stdenv.isLinux {
    atuin-daemon = {
      Unit = {
        Description = "Atuin sync daemon";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${atuinBin} daemon start";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };

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
