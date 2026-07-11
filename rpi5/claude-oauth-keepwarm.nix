# Generic builder for a Claude Code OAuth keep-warm sidecar: a token-refresh
# timer (headless `claude -p` query to force rotation during idle periods)
# plus a token-extract oneshot + path unit that mirrors the current OAuth
# access token from a CLAUDE_CONFIG_DIR's credentials.json to a
# world-readable file under /run, for tiny-llm-gate's FileBearer auth.
#
# Used for both the primary account (claude-remote-control.nix, suffix "",
# configDir null = default ~/.claude) and any secondary gate-only accounts
# (claude-oauth-2.nix, suffix "-2", explicit configDir).
{ pkgs, username }:
{
  # Appended to service/timer/runtime-dir names (e.g. "-2") and description.
  suffix ? "",
  # CLAUDE_CONFIG_DIR override. null means the default ~/.claude (no env
  # var needed — that's where a bare `claude` invocation already reads from).
  configDir ? null,
  # Path to the credentials.json this account's extractor watches/reads.
  credentialsFile,
  # Stagger boot-time refreshes across accounts so they don't race.
  onBootSec ? "15min",
  # Extra `after`/`wants` for the extract service (e.g. the primary account's
  # extractor waits on claude-remote-control.service to seed credentials).
  extractAfter ? [ ],
}:
let
  oauthDirName = "claude-oauth${suffix}";
  oauthPath = "/run/${oauthDirName}/token";

  extractScript = pkgs.writeShellScript "claude-oauth-extract${suffix}" ''
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

  tokenRefreshScript = pkgs.writeShellScript "claude-token-refresh${suffix}" ''
    set -eu
    exec claude -p "say hello world" --dangerously-skip-permissions
  '';
in
{
  inherit oauthPath;

  nixosConfig = {
    systemd.services."claude-token-refresh${suffix}" = {
      description = "Refresh Claude Code OAuth token via headless query${
        if suffix == "" then "" else " (${suffix})"
      }";
      serviceConfig = {
        Type = "oneshot";
        User = username;
        Group = "users";
        ExecStart = tokenRefreshScript;
        Environment = [
          "HOME=/home/${username}"
          "PATH=/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        ] ++ (if configDir == null then [ ] else [ "CLAUDE_CONFIG_DIR=${configDir}" ]);
      };
    };

    systemd.timers."claude-token-refresh${suffix}" = {
      description = "Periodic Claude Code OAuth token refresh timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = onBootSec;
        OnUnitActiveSec = "6h";
        Persistent = true;
      };
    };

    systemd.services."claude-oauth-extract${suffix}" = {
      description = "Extract Claude Code OAuth access token to ${oauthPath}";
      after = extractAfter;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = username;
        Group = "users";
        # RuntimeDirectory creates /run/${oauthDirName} owned by the service
        # user with mode 0755, allowing tiny-llm-gate's DynamicUser to
        # traverse it. RuntimeDirectoryPreserve keeps it alive after exit.
        RuntimeDirectory = oauthDirName;
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = "yes";
        ExecStart = extractScript;
      };
    };

    systemd.paths."claude-oauth-extract${suffix}" = {
      description = "Watch Claude credentials.json for OAuth token changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = credentialsFile;
        Unit = "claude-oauth-extract${suffix}.service";
        TriggerLimitIntervalSec = 0;
      };
    };
  };
}
