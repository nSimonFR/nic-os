{ config, pkgs, lib, tailnetFqdn, ... }:
let
  httpPort = 3100;
  sshPort  = 2222;
in
{
  # ── Forgejo service ───────────────────────────────────────────────────
  services.forgejo = {
    enable = true;

    database = {
      type = "postgres";
      createDatabase = true;
    };

    settings = {
      server = {
        HTTP_ADDR          = "127.0.0.1";
        HTTP_PORT          = httpPort;
        DOMAIN             = tailnetFqdn;
        ROOT_URL           = "https://${tailnetFqdn}:${toString httpPort}/";
        START_SSH_SERVER   = true;
        SSH_SERVER_HOST    = "0.0.0.0";
        BUILTIN_SSH_SERVER_USER = "git";
        SSH_PORT           = sshPort;
      };

      service = {
        DISABLE_REGISTRATION = true;
      };

      mirror = {
        ENABLED          = true;
        DEFAULT_INTERVAL = "8h";
      };

      "cron.update_mirrors" = {
        SCHEDULE = "0 */4 * * *";
      };

      indexer = {
        REPO_INDEXER_ENABLED = false;
      };

      ui = {
        DEFAULT_THEME = "forgejo-auto";
      };
    };

    dump = {
      enable   = true;
      interval = "daily";
    };
  };

  # ── Memory limits (4 GiB RPi5) ───────────────────────────────────────
  systemd.services.forgejo.serviceConfig.MemoryMax = "384M";

  # ── PostgreSQL backup (appends to list in backups.nix) ─────────────────
  services.postgresqlBackup.databases = [ "forgejo" ];

  # ── GitHub mirror sync (discover + create new mirrors) ────────────────
  systemd.services.forgejo-mirror-sync = {
    description = "Discover and mirror new GitHub repos into Forgejo";
    after    = [ "forgejo.service" "network-online.target" ];
    wants    = [ "network-online.target" ];
    requires = [ "forgejo.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "nsimon";
    };
    path = [ pkgs.gh pkgs.curl pkgs.jq ];
    environment.HOME = "/home/nsimon";
    script = ''
      set -euo pipefail

      GITHUB_USER="nSimonFR"
      FORGEJO_URL="http://127.0.0.1:${toString httpPort}"
      FORGEJO_API="$FORGEJO_URL/api/v1"

      # GitHub auth via gh CLI (already authenticated for nsimon)
      GITHUB_TOKEN=$(${pkgs.gh}/bin/gh auth token)

      # Forgejo API token (created once after first login)
      FORGEJO_TOKEN_FILE="/var/lib/forgejo/api-token"
      if [ ! -f "$FORGEJO_TOKEN_FILE" ]; then
        echo "No Forgejo API token found at $FORGEJO_TOKEN_FILE"
        echo "Create one via Forgejo UI: Settings > Applications > Generate Token"
        echo "Then: echo '<token>' | sudo tee $FORGEJO_TOKEN_FILE && sudo chown forgejo:forgejo $FORGEJO_TOKEN_FILE && sudo chmod 600 $FORGEJO_TOKEN_FILE"
        exit 0
      fi
      FORGEJO_TOKEN=$(cat "$FORGEJO_TOKEN_FILE")

      # List existing Forgejo repos to skip already-mirrored ones
      existing=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$FORGEJO_API/repos/search?limit=200" | jq -r '.data[].name // empty' 2>/dev/null || echo "")

      # List all GitHub repos (owner only, paginated via gh)
      ${pkgs.gh}/bin/gh api --paginate "/users/$GITHUB_USER/repos?type=owner&per_page=100" \
        | jq -c '.[]' | while read -r repo; do

        name=$(echo "$repo" | jq -r '.name')
        clone_url=$(echo "$repo" | jq -r '.clone_url')
        description=$(echo "$repo" | jq -r '.description // ""')
        private=$(echo "$repo" | jq -r '.private')

        # Skip if already mirrored
        if echo "$existing" | grep -qx "$name"; then
          continue
        fi

        echo "Creating mirror: $name (private=$private)"

        curl -sf -X POST \
          -H "Authorization: token $FORGEJO_TOKEN" \
          -H "Content-Type: application/json" \
          "$FORGEJO_API/repos/migrate" \
          -d "$(jq -n \
            --arg clone_addr "$clone_url" \
            --arg auth_token "$GITHUB_TOKEN" \
            --arg repo_name "$name" \
            --arg description "$description" \
            --argjson private "$private" \
            --arg service "github" \
            '{
              clone_addr: $clone_addr,
              auth_token: $auth_token,
              repo_name: $repo_name,
              repo_owner: "nsimon",
              description: $description,
              private: $private,
              mirror: true,
              service: $service,
              issues: false,
              labels: false,
              milestones: false,
              pull_requests: false,
              releases: true,
              wiki: false,
              lfs: false
            }')" || echo "  WARN: failed to mirror $name"
      done

      echo "Mirror sync complete."
    '';
  };

  systemd.timers.forgejo-mirror-sync = {
    description = "Daily GitHub mirror discovery for Forgejo";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
    };
  };
}
