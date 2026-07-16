{ pkgs, lib, username, telegramChatId, ... }:
let
  sessionName = "claude-rc";
  # claude-rc auto-resume: detect bridge sessions stalled at the Claude usage
  # cap and resume them headlessly once the window resets. LIVE — performs real
  # `claude -p --resume` once a blocking rate_limit_event's window has reset.
  # NOTE: the blocking status string is still inferred (CRC_BLOCKING_STATUSES
  # defaults to `overuse_denied`); only `allowed_warning` has been seen in the
  # wild, so until a real cap validates the trigger, a live resume may not fire.
  # The watcher logs every rate_limit_event it sees, so the first real cap
  # reveals the true status string. Set back to true to revert to log/notify.
  autoResumeDryRun = false;
  telegramTokenFile = "/run/agenix/telegram-bot-token";
  claudeRc = "/home/${username}/.claude/bin/claude-rc";
  credentialsFile = "/home/${username}/.claude/.credentials.json";
  sessionsDir = "/home/${username}/.claude/sessions";
  projectsDir = "/home/${username}/.claude/projects";
  worktreesDir = "/home/${username}/nic-os/.claude/worktrees";

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

  startScript = pkgs.writeShellScript "claude-remote-control-start" ''
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
    ${pkgs.tmux}/bin/tmux new-session -d -s ${sessionName} \
      "CLAUDE_CONFIG_DIR=${configDir} ${claudeRc} \
        --spawn worktree \
        --no-create-session-in-dir \
        --capacity 8 \
        --permission-mode bypassPermissions \
        --name rpi5 \
        --verbose \
        --debug-file /tmp/claude-rc-debug.log"
  '';

  watchdogScript = pkgs.writeShellScript "claude-remote-control-watchdog" ''
    # tmux server is per-user; point to the user's socket
    TMUX_SOCKET="/tmp/tmux-$(id -u ${username})/default"
    if ! ${pkgs.tmux}/bin/tmux -S "$TMUX_SOCKET" has-session -t ${sessionName} 2>/dev/null; then
      echo "tmux session ${sessionName} missing, restarting service"
      systemctl restart claude-remote-control.service
    fi
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
    # Stop cleanly before rebuilds: nixos-rebuild triggers stop→start
    stopIfChanged = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = username;
      Group = "users";
      WorkingDirectory = "/home/${username}/nic-os";
      ExecStartPre = prepConfigScript;
      ExecStart = startScript;
      ExecStop = stopScript;
      TimeoutStopSec = "10s";
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

  # Auto-resume bridge sessions stalled at the Claude usage cap. Each tick
  # scans active bridge sessions for a blocking rate_limit_event and, once the
  # window resets, resumes the conversation (dry-run by default — see
  # autoResumeDryRun above). Logic lives in ./scripts/claude-rc-autoresume.py.
  systemd.services.claude-rc-autoresume = {
    description = "Auto-resume rate-limited claude-rc bridge sessions after cap reset";
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/claude-rc-autoresume.py}";
      Environment = [
        "HOME=/home/${username}"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        "CRC_DRY_RUN=${if autoResumeDryRun then "1" else "0"}"
        "CRC_SESSIONS_DIR=${sessionsDir}"
        "CRC_PROJECTS_DIR=${projectsDir}"
        "CRC_CLAUDE_BIN=/home/${username}/.local/state/nix/profiles/home-manager/home-path/bin/claude"
        "CRC_TELEGRAM_TOKEN_FILE=${telegramTokenFile}"
        "CRC_TELEGRAM_CHAT_ID=${toString telegramChatId}"
      ];
    };
  };

  systemd.timers.claude-rc-autoresume = {
    description = "claude-rc auto-resume timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
    };
  };

}
