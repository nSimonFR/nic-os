{ pkgs, username, ... }:
let
  sessionName = "claude-rc";
  claudeRc = "/home/${username}/.claude/bin/claude-rc";
  credentialsFile = "/home/${username}/.claude/.credentials.json";
  # RuntimeDirectory places the file under /run (owned by the service user);
  # tiny-llm-gate reads from the full path.
  claudeOauthDir = "claude-oauth";                  # relative to /run
  claudeOauthPath = "/run/${claudeOauthDir}/token";
  sessionsDir = "/home/${username}/.claude/sessions";
  projectsDir = "/home/${username}/.claude/projects";
  worktreesDir = "/home/${username}/nic-os/.claude/worktrees";

  # Extracts the current OAuth access token from ~/.claude/.credentials.json
  # and writes it atomically to /run/claude-oauth/token. The long-running
  # claude-remote-control process keeps credentials.json fresh by refreshing
  # the token during normal session activity; this extractor is re-triggered
  # on file changes via a path unit so the /run file tracks the refreshes.
  # tiny-llm-gate reads the resulting file on every request (FileBearer auth).
  extractScript = pkgs.writeShellScript "claude-oauth-extract" ''
    set -eu
    umask 0333  # -r--r--r-- so tiny-llm-gate (DynamicUser) can read it
    # $RUNTIME_DIRECTORY is set by systemd via RuntimeDirectory=
    dest="$RUNTIME_DIRECTORY/token"
    token=$(${pkgs.jq}/bin/jq -r '.claudeAiOauth.accessToken // empty' ${credentialsFile})
    if [ -z "$token" ]; then
      echo "no accessToken in credentials file" >&2
      exit 1
    fi
    tmp="$dest.new"
    printf '%s' "$token" > "$tmp"
    mv "$tmp" "$dest"
  '';

  # Seconds of conversation inactivity before a bridge session is reaped.
  # Uses the conversation JSONL file mtime (updated on every user/assistant
  # message) — much more accurate than process age since a session can be
  # idle but resumable. 2 hours means: if nobody has talked to this session
  # for 2h, it's safe to reclaim.
  maxInactivitySec = "7200"; # 2h

  stopScript = pkgs.writeShellScript "claude-remote-control-stop" ''
    # Send SIGTERM to the claude process inside tmux, giving it time
    # to deregister from Anthropic's API before we kill the session.
    ${pkgs.tmux}/bin/tmux send-keys -t ${sessionName} C-c 2>/dev/null || true
    sleep 3
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
  '';

  startScript = pkgs.writeShellScript "claude-remote-control-start" ''
    ${pkgs.tmux}/bin/tmux kill-session -t ${sessionName} 2>/dev/null || true
    ${pkgs.tmux}/bin/tmux new-session -d -s ${sessionName} \
      "${claudeRc} \
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
{
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

  # OAuth token extractor: keeps /run/claude-oauth in sync with the current
  # access token in ~/.claude/.credentials.json. Runs as the owning user
  # because the credentials file is mode 0600. Output is world-readable so
  # tiny-llm-gate (DynamicUser) can consume it.
  systemd.services.claude-oauth-extract = {
    description = "Extract Claude Code OAuth access token to ${claudeOauthPath}";
    # Run once at boot after the remote-control service has started (which
    # ensures the credentials file is populated), then re-run on file changes
    # via the path unit below.
    after = [ "claude-remote-control.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      # RuntimeDirectory creates /run/claude-oauth owned by the service user
      # with mode 0755, allowing tiny-llm-gate's DynamicUser to traverse it.
      # RuntimeDirectoryPreserve keeps the dir alive after the oneshot exits.
      RuntimeDirectory = claudeOauthDir;
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = "yes";
      ExecStart = extractScript;
    };
  };

  systemd.paths.claude-oauth-extract = {
    description = "Watch Claude credentials.json for OAuth token changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = credentialsFile;
      # Default Unit= is <name>.service — explicit for clarity.
      Unit = "claude-oauth-extract.service";
      # Allow rapid re-triggering (default is 2s debounce which is fine,
      # but make it explicit that we don't want triggers dropped).
      TriggerLimitIntervalSec = 0;
    };
  };
}
