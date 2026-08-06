{ pkgs, lib, username, telegramChatId, ... }:
let
  sessionName = "claude-rc";
  telegramTokenFile = "/run/agenix/telegram-bot-token";
  # One-shot seam (shared/notify.nix): "resumed N sessions after boot" is an
  # event, not a condition that later clears.
  telegramSend = (import ../shared/notify.nix { inherit pkgs; }).send {
    tokenFile = telegramTokenFile;
    chatId = telegramChatId;
    name = "claude-rc-telegram-send";
  };

  # Boot/restart auto-resume: when the bridge (re)starts, re-host the sessions
  # that were live before, so a reboot or watchdog restart doesn't leave every
  # remote session dead until the user pokes it from the app. Mechanism (see the
  # script header): read this bridge's environment id from its own
  # bridge-pointer.json, then
  # POST /v1/environments/<env>/bridge/reconnect {session_id} per session — the
  # account OAuth token alone is accepted; a *fresh* bridge then work-polls the
  # re-queued session and spawns its worker. Replaces the old cap-autoresume,
  # which used `claude -p --resume` (a silent in-app no-op). Live: on a fresh
  # bridge (reboot / watchdog restart) it actually re-hosts the snapshotted
  # sessions. Safe to run live now that PR#441 stopped the watchdog thrash, so
  # bridge restarts are rare/legitimate rather than every 5min.
  bootResumeDryRun = false;
  bootResumeState = "/home/${username}/.claude/state/claude-rc-boot-resume";
  orgUuid = "49157a56-e1c6-4ec1-8ad4-032f3125e527";
  bootResume = "${pkgs.python3}/bin/python3 ${./scripts/claude-rc-boot-resume.py}";
  claudeRc = "/home/${username}/.claude/bin/claude-rc";
  credentialsFile = "/home/${username}/.claude/.credentials.json";
  sessionsDir = "/home/${username}/.claude/sessions";
  projectsDir = "/home/${username}/.claude/projects";
  worktreesDir = "/home/${username}/nic-os/.claude/worktrees";
  # The directory the bridge serves. Also part of the bridge-pointer.json path
  # (claude slugifies it), which is how boot-resume finds the live environment.
  workingDir = "/home/${username}/nic-os";

  # Isolated CLAUDE_CONFIG_DIR for the bridge only. Remote Control in
  # claude-code >= 2.1.x hard-refuses any API endpoint other than
  # api.anthropic.com — the guard's bypass hook is compiled to always-false, so
  # there is no env escape. But ~/.claude/settings.json forces the Aperture gate
  # URL globally, and settings.json `env` outranks process env, so the bridge
  # tripped the guard and exited 0 on every start (masked as active by
  # RemainAfterExit; respawned every 5min by the watchdog). We shadow the real
  # config here: symlink all state so OAuth, sessions/projects, skills, and the
  # credentials.json that claude-oauth-extract watches stay authoritative in
  # ~/.claude, and generate a settings.json whose only change is the base URL
  # forced to direct Anthropic — the same escape the `claude-direct` shell alias
  # already uses. Sessions the bridge spawns inherit this dir (direct Anthropic,
  # bypassing the gate) which matches that established choice.
  configDir = "/home/${username}/.claude-rc";

  # OAuth keep-warm sidecar (token-refresh timer + extract-to-/run unit) for
  # this account. The long-running claude-remote-control process keeps
  # credentials.json fresh by refreshing the token during normal session
  # activity; the refresh timer below covers idle stretches. See
  # claude-oauth-keepwarm.nix (shared with the account-2 gate-only spare in
  # claude-oauth-2.nix).
  keepWarm = import ./claude-oauth-keepwarm.nix { inherit pkgs username; } {
    inherit credentialsFile;
    extractAfter = [ "claude-remote-control.service" ];
  };

  # Seconds of conversation inactivity before a bridge session is reaped.
  # Uses the conversation JSONL file mtime (updated on every user/assistant
  # message) — much more accurate than process age since a session can be
  # idle but resumable.
  #
  # Tuning: JSONL mtime conflates "user is thinking / away for a while" with
  # "session was orphaned by the mobile app and will never come back". With no
  # cheap way to distinguish the two (heartbeat API still returns state=active
  # for orphaned sessions — see anthropics/claude-code#28914 closed
  # NOT_PLANNED), err on the side of preserving real work: 24h survives
  # overnight pauses, lunch breaks, and weekend handoffs. Worst case for
  # orphans: each holds ~70MB RSS + a worktree dir for up to a day. Bounded
  # by maxSessions=8 in startScript, so ~560MB ceiling — fine on the rpi5.
  maxInactivitySec = "86400"; # 24h

  stopScript = pkgs.writeShellScript "claude-remote-control-stop" ''
    # Send SIGTERM to the claude process inside tmux, giving it time
    # to deregister from Anthropic's API before we kill the session.
    ${pkgs.tmux}/bin/tmux send-keys -t ${sessionName} C-c 2>/dev/null || true
    sleep 3
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
  '';

  # post-checkout hook that re-gates RC bridge worker sessions to Aperture.
  # The bridge's isolated config forces direct Anthropic (to pass the Remote
  # Control guard), so worker sessions spawned into worktrees would bypass the
  # gate. This hook drops a project-level settings.json (base URL = gate) into
  # each bridge-created worktree; workers don't run the guard, so they're free
  # to use the gate. Guarded by CLAUDE_CONFIG_DIR → no-op for normal checkouts.
  worktreeGateHook = pkgs.writeShellScript "claude-rc-worktree-gate"
    (builtins.readFile ./scripts/claude-rc-worktree-gate.sh);

  # Build the isolated bridge config dir (see configDir note above) before each
  # start, refreshing symlinks and regenerating settings.json so it tracks any
  # change to the real ~/.claude/settings.json.
  prepConfigScript = pkgs.writeShellScript "claude-rc-prep-config" ''
    set -eu
    export PATH="${pkgs.jq}/bin:${pkgs.coreutils}/bin:$PATH"
    src="/home/${username}/.claude"
    dst="${configDir}"
    mkdir -p "$dst"
    # Mirror every real config entry as a symlink (credentials, sessions,
    # projects, skills, plugins, settings.local.json, ...) except settings.json,
    # which is generated below. Keeps all state authoritative in ~/.claude.
    for entry in "$src"/* "$src"/.[!.]*; do
      [ -e "$entry" ] || continue
      name="$(basename "$entry")"
      [ "$name" = "settings.json" ] && continue
      ln -sfn "$entry" "$dst/$name"
    done
    # Account/org state lives at $HOME/.claude.json (outside .claude); Remote
    # Control needs it to resolve org eligibility.
    ln -sfn "/home/${username}/.claude.json" "$dst/.claude.json"
    # settings.json = real settings with the one key the guard checks overridden.
    jq '.env.ANTHROPIC_BASE_URL = "https://api.anthropic.com"' \
      "$src/settings.json" > "$dst/settings.json"

    # Install the worktree-gate post-checkout hook (symlink to the versioned
    # script). Only if absent or already a symlink — never clobber a foreign hook.
    hook="/home/${username}/nic-os/.git/hooks/post-checkout"
    if [ ! -e "$hook" ] || [ -L "$hook" ]; then
      ln -sfn ${worktreeGateHook} "$hook"
    else
      echo "post-checkout hook exists and is not ours; skipping worktree-gate install" >&2
    fi
  '';

  # NOTE: --create-session-in-dir (the default) is LOAD-BEARING for session
  # recovery — do not re-add --no-create-session-in-dir.
  #
  # The bridge only keeps its environment across a restart if it wrote
  # $CLAUDE_CONFIG_DIR/projects/<slugified-dir>/bridge-pointer.json. Reversing
  # claude-code 2.1.217 (`bin/.claude-wrapped`), the write is gated on having a
  # session to anchor the pointer to:
  #
  #   let cr = Xe ?? de ?? null;                    // resumed / adopted session
  #   if (ie && !Xe && !de) cr = await createBridgeSession(...)   // ie = createSessionInDir
  #   let Xt = cr ?? (preserveOnShutdown ? ne ?? "" : null);
  #   if (Xt !== null && !ae)
  #     if (await writeBridgePointer(dir, {sessionId: Xt, environmentId, source: "standalone", ...}))
  #       preserveOnShutdown = true, ownsPointer = true;
  #
  # With --no-create-session-in-dir, ie=false => cr=null => Xt=null => the
  # pointer is never written => preserveOnShutdown stays false. On shutdown the
  # bridge then takes the other branch and calls deregisterEnvironment(), so the
  # environment is DELETED server-side (GET returns 404, not archived). The next
  # start finds no pointer, requests no reuse, and registers a brand-new env.
  # Every previously-live session then belongs to an environment that no longer
  # exists, and POST /v1/environments/<new-env>/bridge/reconnect answers
  # 400 "Session does not belong to this environment." — which is exactly why
  # claude-rc-boot-resume revived 0/3 sessions on its first live run.
  #
  # Letting it default to on makes the bridge pre-create one anchor session in
  # this cwd, which anchors the pointer => preserveOnShutdown=true => shutdown
  # skips archive+deregister ("Environment preserved.") => next start reads the
  # pointer and registers with reuseEnvironmentId => SAME env id, and the anchor
  # session is re-adopted via bridge/reconnect. Verified end-to-end against a
  # throwaway bridge in /tmp: same env id and same session id across a full
  # SIGTERM/restart cycle.
  #
  # Cost: one always-on anchor session in this directory (1 of capacity 8). It
  # is a placeholder — it is NOT spawned into a worktree, so it does not get the
  # worktree-gate post-checkout settings.json and would talk to Anthropic
  # directly rather than through the Aperture gate if anyone actually used it.
  # Leave it idle; open worktree sessions from claude.ai/code instead.
  startScript = pkgs.writeShellScript "claude-remote-control-start" ''
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
    ${pkgs.tmux}/bin/tmux new-session -d -s ${sessionName} \
      "CLAUDE_CONFIG_DIR=${configDir} ${claudeRc} \
        --spawn worktree \
        --capacity 8 \
        --permission-mode bypassPermissions \
        --name rpi5 \
        --verbose \
        --debug-file /tmp/claude-rc-debug.log"
  '';

  # Health = the bridge PROCESS is alive, not "does a tmux window exist". The
  # tmux wrapper is incidental, and probing the per-user tmux socket from this
  # root-run watchdog was fragile: right after a nixos-rebuild restart the
  # socket churns, and a single `has-session` probe (with stderr swallowed)
  # would hang/error and read identically to "session dead" -> the watchdog
  # SIGKILLed a healthy, in-use bridge every 5min (restart's ExecStop reliably
  # hits TimeoutStopSec). Fixes: (1) check the process directly via pgrep,
  # (2) debounce over 3 probes so a momentary blip never triggers a restart,
  # (3) don't swallow tmux stderr, so a real fault is diagnosable in the log.
  watchdogScript = pkgs.writeShellScript "claude-remote-control-watchdog" ''
    export PATH="${pkgs.procps}/bin:${pkgs.tmux}/bin:${pkgs.coreutils}/bin:$PATH"
    uid="$(id -u ${username})"
    tmux_socket="/tmp/tmux-$uid/default"

    alive() {
      # Primary signal: the bridge process itself.
      pgrep -u "$uid" -f 'remote-control --spawn' >/dev/null && return 0
      # Fallback: the tmux window, in case the cmdline pattern ever drifts.
      # Stderr is intentionally NOT discarded so socket faults show in the log.
      tmux -S "$tmux_socket" has-session -t ${sessionName} && return 0
      return 1
    }

    for i in 1 2 3; do
      alive && exit 0
      [ "$i" -lt 3 ] && sleep 3
    done

    echo "bridge absent on 3 probes over ~6s, restarting service"
    systemctl restart claude-remote-control.service
  '';

  # Kill stale bridge sessions and clean up orphaned worktrees.
  # Works around: anthropics/claude-code#29313, #26725
  #
  # The bug: deleting a session from claude.ai/code does NOT signal
  # the remote process to exit. The heartbeat API keeps returning
  # state=active forever. So we detect staleness via conversation
  # file inactivity (JSONL mtime) which is updated on every real
  # user/assistant message — much more reliable than process age.
  cleanupScript = pkgs.writeShellScript "claude-rc-session-cleanup" ''
    export PATH="${pkgs.jq}/bin:${pkgs.git}/bin:${pkgs.procps}/bin:${pkgs.findutils}/bin:$PATH"
    SESSIONS_DIR="${sessionsDir}"
    PROJECTS_DIR="${projectsDir}"
    WORKTREES_DIR="${worktreesDir}"
    MAX_INACTIVITY="${maxInactivitySec}"
    now="$(date +%s)"
    killed=0

    for f in "$SESSIONS_DIR"/*.json; do
      [ -f "$f" ] || continue
      pid="$(basename "$f" .json)"
      entrypoint="$(jq -r '.entrypoint // ""' "$f")"

      # Only target bridge sessions (spawned by remote-control for web UI)
      [ "$entrypoint" = "sdk-cli" ] || continue

      # Skip if process is already dead — just clean up the file
      [ -d "/proc/$pid" ] || {
        echo "removing stale session file for dead PID $pid"
        rm -f "$f"
        killed=$((killed + 1))
        continue
      }

      # Find the conversation JSONL file to check last real activity
      session_id="$(jq -r '.sessionId // ""' "$f")"
      [ -z "$session_id" ] && continue

      conv_file="$(find "$PROJECTS_DIR" -name "''${session_id}.jsonl" -print -quit 2>/dev/null)"
      if [ -n "$conv_file" ] && [ -f "$conv_file" ]; then
        last_mod="$(stat -c %Y "$conv_file")"
        idle_sec=$(( now - last_mod ))
      else
        # No conversation file means it never got a message — use process age
        idle_sec="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
        [ -z "$idle_sec" ] && continue
      fi

      if [ "$idle_sec" -gt "$MAX_INACTIVITY" ]; then
        idle_min=$(( idle_sec / 60 ))
        echo "killing stale bridge session PID=$pid sid=$session_id (inactive ''${idle_min}min > $((MAX_INACTIVITY/60))min)"
        kill "$pid" 2>/dev/null
        sleep 2
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$f"
        killed=$((killed + 1))
      fi
    done

    # Clean up orphaned worktrees (bridge-cse_* dirs whose process is gone)
    if [ -d "$WORKTREES_DIR" ]; then
      for wt in "$WORKTREES_DIR"/bridge-cse_*; do
        [ -d "$wt" ] || continue
        wt_name="$(basename "$wt")"
        # Check if any running claude process uses this worktree
        in_use=0
        for f in "$SESSIONS_DIR"/*.json; do
          [ -f "$f" ] || continue
          pid="$(basename "$f" .json)"
          [ -d "/proc/$pid" ] || continue
          cwd="$(jq -r '.cwd // ""' "$f")"
          case "$cwd" in
            *"$wt_name"*) in_use=1; break ;;
          esac
        done
        if [ "$in_use" = "0" ]; then
          # Preserve recently-active worktrees even with no live worker. A bridge
          # worker process only exists mid-turn, so an idle-but-resumable session
          # — and, right after a reboot, EVERY session until it is re-hosted — has
          # no live cwd here and would be reaped, which deletes the worktree and
          # freezes the session permanently (the app has nothing to spawn into).
          # Gate on the transcript JSONL mtime, the same 24h window the stale-
          # process loop above uses. Workers run with CLAUDE_CONFIG_DIR=~/.claude-rc
          # whose projects/ symlink points into $PROJECTS_DIR; the transcript dir
          # is the worktree path slugified (every non-alphanumeric char -> '-').
          slug="$(printf '%s' "$wt" | tr -c 'A-Za-z0-9' '-')"
          conv_dir="$PROJECTS_DIR/$slug"
          last_mod=0
          if [ -d "$conv_dir" ]; then
            last_mod="$(find "$conv_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@\n' 2>/dev/null \
              | cut -d. -f1 | sort -rn | head -1)"
            [ -z "$last_mod" ] && last_mod=0
          fi
          if [ "$last_mod" -gt 0 ] && [ "$(( now - last_mod ))" -le "$MAX_INACTIVITY" ]; then
            echo "preserving recently-active worktree: $wt_name (idle $(( (now - last_mod) / 60 ))min)"
            continue
          fi
          echo "removing orphaned worktree: $wt_name"
          git -C /home/${username}/nic-os worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
        fi
      done
      git -C /home/${username}/nic-os worktree prune 2>/dev/null || true
    fi

    [ "$killed" -gt 0 ] && echo "cleaned up $killed stale session(s)" || echo "no stale sessions found"
  '';
in
lib.recursiveUpdate keepWarm.nixosConfig {
  systemd.services.claude-remote-control = {
    description = "Claude Code Remote Control server (tmux)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # Never let activation touch the bridge. It hosts the tmux server that any
    # Claude session rebuilding this box is running inside, so a stop→start here
    # kills the caller mid-activation: nixos-rebuild hands
    # switch-to-configuration its own stdout via `systemd-run --pipe`, that pipe
    # dies with the caller, and the next write panics it with exit 101 — leaving
    # everything nixos-rebuild-safe had stopped stopped. Twice on 2026-07-29,
    # once for 1d15h (Home Assistant, AFFiNE, Ryot, Dawarich, homepage).
    # Config changes here need a manual `systemctl restart
    # claude-remote-control`; ExecStop snapshots the live sessions and
    # boot-resume re-hosts them, same as a watchdog restart.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = username;
      Group = "users";
      WorkingDirectory = workingDir;
      ExecStartPre = prepConfigScript;
      ExecStart = startScript;
      # Snapshot the live session set before tearing the bridge down, then stop.
      ExecStop = [ "${bootResume} snapshot" "${stopScript}" ];
      TimeoutStopSec = "15s";
      Environment = [
        "HOME=/home/${username}"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
  };

  systemd.services.claude-remote-control-watchdog = {
    description = "Claude Code Remote Control watchdog";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = watchdogScript;
    };
  };

  systemd.timers.claude-remote-control-watchdog = {
    description = "Claude Code Remote Control watchdog timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };

  # Periodic cleanup of stale bridge sessions that the web UI failed to terminate.
  # Workaround for anthropics/claude-code#29313 and #26725.
  systemd.services.claude-rc-session-cleanup = {
    description = "Claude RC stale session cleanup";
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      ExecStart = cleanupScript;
      Environment = [
        "HOME=/home/${username}"
      ];
    };
  };

  systemd.timers.claude-rc-session-cleanup = {
    description = "Claude RC stale session cleanup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "30min";
    };
  };

  # Snapshot the recently-active bridge sessions periodically (and on clean stop,
  # via the bridge's ExecStop) so a restarted/rebooted bridge knows which sessions
  # to re-host. Enumerated from the on-disk bridge-cse_* worktrees + transcript
  # mtimes (both survive a reboot), NOT live worker PIDs — a worker only exists
  # mid-turn, so the old PID snapshot was empty on every real reboot and revived
  # nothing. Bounded to the maxInactivitySec (24h) recency window.
  systemd.services.claude-rc-snapshot = {
    description = "Snapshot live claude-rc bridge sessions for boot-resume";
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      ExecStart = "${bootResume} snapshot";
      Environment = [
        "HOME=/home/${username}"
        "CRC_PROJECTS_DIR=${projectsDir}"
        "CRC_WORKTREES_DIR=${worktreesDir}"
        "CRC_SNAPSHOT_FILE=${bootResumeState}/snapshot.json"
        "CRC_RECENCY_SECONDS=${maxInactivitySec}"
      ];
    };
  };

  systemd.timers.claude-rc-snapshot = {
    description = "claude-rc live-session snapshot timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "3min";
    };
  };

  # Re-host previously-live sessions whenever the bridge (re)starts. Pulled in by
  # the bridge via wantedBy (fires on boot AND on every watchdog restart) and
  # ordered after it. Validated mechanism lives in ./scripts/claude-rc-boot-resume.py.
  systemd.services.claude-rc-boot-resume = {
    description = "Re-host previously-live claude-rc sessions on bridge (re)start";
    after = [ "claude-remote-control.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "claude-remote-control.service" ];
    partOf = [ "claude-remote-control.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      WorkingDirectory = workingDir;
      ExecStart = "${bootResume} resume";
      Environment = [
        "HOME=/home/${username}"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        "CRC_DRY_RUN=${if bootResumeDryRun then "1" else "0"}"
        "CRC_SNAPSHOT_FILE=${bootResumeState}/snapshot.json"
        "CRC_STATE_FILE=${bootResumeState}/handled.json"
        "CRC_SESSIONS_DIR=${sessionsDir}"
        "CRC_PROJECTS_DIR=${projectsDir}"
        "CRC_CREDENTIALS_FILE=${configDir}/.credentials.json"
        "CRC_WORKTREES_DIR=${worktreesDir}"
        "CRC_DEVICE_NAME=rpi5"
        # Where the bridge runs + its config dir: together these locate
        # bridge-pointer.json, the authoritative source for the environment id
        # to reconnect against (see current_env_id in the script).
        "CRC_BRIDGE_DIR=${workingDir}"
        "CRC_CONFIG_DIR=${configDir}"
        "CRC_ORG_UUID=${orgUuid}"
        "CRC_RECENCY_SECONDS=${maxInactivitySec}"
        "CRC_TELEGRAM_SEND=${telegramSend}"
      ];
    };
  };

}
