# Keep-warm + token-extract sidecar for the second Anthropic account used by
# tiny-llm-gate's multi-account failover. Unlike account 1 (the user's
# daily-driver login, kept fresh by claude-remote-control.nix's 24/7 bridge),
# account 2 is gate-only and nothing else touches it interactively — so it
# only needs the lightweight refresh-timer + extract-on-change pieces, not
# the full tmux bridge.
#
# Login is a manual one-time step (OAuth needs a real browser/device flow):
#   CLAUDE_CONFIG_DIR=~/.claude-secondary claude
# Keep this account dedicated to the gate — using it for real interactive
# work doesn't break anything structurally, but stops it being a clean spare.
{ pkgs, username, ... }:
let
  credentialsFile = "/home/${username}/.claude-secondary/.credentials.json";
  claudeOauthDir = "claude-oauth-2"; # relative to /run
  claudeOauthPath = "/run/${claudeOauthDir}/token";

  # Same shape as claude-remote-control.nix's extractScript, pointed at the
  # secondary account's credentials file and runtime directory.
  extractScript = pkgs.writeShellScript "claude-oauth-extract-2" ''
    set -eu
    umask 0333  # -r--r--r-- so tiny-llm-gate (DynamicUser) can read it
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

  # Headless no-op query to force a token refresh during idle periods —
  # same purpose as claude-token-refresh, scoped to the secondary account via
  # CLAUDE_CONFIG_DIR.
  tokenRefreshScript = pkgs.writeShellScript "claude-token-refresh-2" ''
    set -eu
    exec claude -p "say hello world" --dangerously-skip-permissions
  '';
in
{
  systemd.services.claude-token-refresh-2 = {
    description = "Refresh secondary Claude Code OAuth token via headless query";
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      ExecStart = tokenRefreshScript;
      Environment = [
        "HOME=/home/${username}"
        "CLAUDE_CONFIG_DIR=/home/${username}/.claude-secondary"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
  };

  systemd.timers.claude-token-refresh-2 = {
    description = "Periodic secondary Claude Code OAuth token refresh timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "20min"; # offset from the account-1 timer's 15min
      OnUnitActiveSec = "6h";
      Persistent = true;
    };
  };

  systemd.services.claude-oauth-extract-2 = {
    description = "Extract secondary Claude Code OAuth access token to ${claudeOauthPath}";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      RuntimeDirectory = claudeOauthDir;
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = "yes";
      ExecStart = extractScript;
    };
  };

  systemd.paths.claude-oauth-extract-2 = {
    description = "Watch secondary Claude credentials.json for OAuth token changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = credentialsFile;
      Unit = "claude-oauth-extract-2.service";
      TriggerLimitIntervalSec = 0;
    };
  };
}
