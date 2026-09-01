{ config, pkgs, lib, tailnetFqdn, ... }:
let
  # externalPort: what Tailscale Serve exposes and ROOT_URL advertises.
  # Now bound by the socket-activate proxy (hosts/rpi5/lib/socket-activate.nix),
  # which forwards to forgejo on backendPort when there is traffic.
  externalPort = 3100;
  backendPort  = 3101;
  sshPort      = 2222;

  earl-grey-theme = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/Troplo/earl-grey/master/theme-earl-grey.css";
    hash = "sha256-UNc+idYpmCcNXxf7IRnsTzeWT2nB4HQOStnQxUsC0n8=";
  };
in
{
  # ── Forgejo service ───────────────────────────────────────────────────
  services.forgejo = {
    enable = true;

    database = {
      type = "postgres";
      createDatabase = true;
    };

    repositoryRoot = "/mnt/data/repositories";

    settings = {
      server = {
        HTTP_ADDR          = "127.0.0.1";
        HTTP_PORT          = backendPort;
        DOMAIN             = tailnetFqdn;
        ROOT_URL           = "https://${tailnetFqdn}:${toString externalPort}/";
        START_SSH_SERVER   = true;
        SSH_SERVER_HOST    = "127.0.0.1";
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

      # ── Memory optimization for 4 GiB RPi5 ──────────────────────────────
      # Default cache keeps up to 50k items for 16h — overkill for a personal instance.
      # TwoQueue LRU with 100 items caps memory growth.
      cache = {
        ADAPTER = "twoqueue";
        HOST = ''{"size":100,"recent_ratio":0.25,"ghost_ratio":0.5}'';
        ITEM_TTL = "4h";
      };

      session = {
        GC_INTERVAL_TIME = 3600;
      };

      ui = {
        THEMES = "forgejo-auto,forgejo-light,forgejo-dark,earl-grey";
        DEFAULT_THEME = "earl-grey";
      };
    };

    # NOTE: `dump` stays off. `forgejo dump` is a migration tool with no
    # incremental mode — each run wrote a standalone ~2.2 GB zip (99.6% of it
    # the bare repos) to /var/lib/forgejo/dump, i.e. the SAME disk as the data
    # it "backed up" and outside restic's /mnt/data scope. 29 retained copies
    # cost 61 GB of root for zero disaster-recovery value. Replaced by
    # forgejo-state-backup below (~300 KB/day, lands on /mnt/data → Storj).
  };

  # ── Earl Grey dark theme ──────────────────────────────────────────────
  systemd.services.forgejo.preStart = lib.mkAfter ''
    mkdir -p ${config.services.forgejo.customDir}/public/assets/css
    ln -sf ${earl-grey-theme} ${config.services.forgejo.customDir}/public/assets/css/theme-earl-grey.css
  '';

  # ── Memory limits (4 GiB RPi5) ───────────────────────────────────────
  systemd.services.forgejo.serviceConfig.MemoryMax = "256M";
  systemd.services.forgejo.environment.GOMEMLIMIT = "200MiB";

  # ── Forgejo state backup (secrets, config, avatars) ────────────────────
  # The repos live on /mnt/data/repositories and the DB is dumped by
  # postgresqlBackup — both already reach Storj via restic. What was NOT
  # covered is the ~440 KB of non-declarative state under /var/lib/forgejo:
  # custom/conf/secret_key (encrypts 2FA secrets, OAuth tokens and mirror
  # passwords stored in the DB), internal_token, oauth2_jwt_secret,
  # data/jwt/private.pem, data/ssh/gitea.rsa (SSH host key) and avatars.
  # Without secret_key a restored DB is undecryptable, so this is the piece
  # that actually makes the other backups restorable.
  systemd.tmpfiles.rules = [
    "d /mnt/data/backups/forgejo 0750 forgejo forgejo -"
  ];

  systemd.services.forgejo-state-backup = {
    description = "Forgejo state backup (secrets, config, avatars)";
    serviceConfig = { Type = "oneshot"; User = "forgejo"; };
    script = ''
      set -euo pipefail
      STAMP=$(${pkgs.coreutils}/bin/date +%F)
      # -z shells out to `gzip` from PATH, which the unit's minimal PATH lacks
      # → absolute path via --use-compress-program (same fix as gramps-web).
      ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip \
        -cf "/mnt/data/backups/forgejo/forgejo-state-$STAMP.tar.gz" \
        -C /var/lib/forgejo --exclude=./dump --exclude=./log .
      ${pkgs.findutils}/bin/find /mnt/data/backups/forgejo \
        -name "forgejo-state-*.tar.gz" -mtime +7 -delete
    '';
  };

  systemd.timers.forgejo-state-backup = {
    description = "Daily Forgejo state backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*-*-* 03:15:00"; Persistent = true; };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────
  # Tailscale Serve and ROOT_URL still point at externalPort. The proxy
  # listens there and wakes forgejo on first request; after idleSec of
  # quiet, forgejo stops to free its ~80 MB RSS.
  services.socketActivate.forgejo = {
    enable    = true;
    realUnit  = "forgejo.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 600;
  };

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
      # Hit the externally-facing port so the socket-activate proxy wakes
      # Forgejo if it has been idle-stopped.
      FORGEJO_URL="http://127.0.0.1:${toString externalPort}"
      FORGEJO_API="$FORGEJO_URL/api/v1"

      # GitHub auth via gh CLI (already authenticated for nsimon)
      GITHUB_TOKEN=$(${pkgs.gh}/bin/gh auth token)

      # Forgejo API token (created once after first login)
      # Stored in /etc/forgejo/ because /var/lib/forgejo is 750 forgejo:forgejo
      FORGEJO_TOKEN_FILE="/etc/forgejo/api-token"
      if [ ! -f "$FORGEJO_TOKEN_FILE" ]; then
        echo "No Forgejo API token found at $FORGEJO_TOKEN_FILE"
        echo "Generate one via CLI or UI, then:"
        echo "  sudo mkdir -p /etc/forgejo"
        echo "  echo '<token>' | sudo tee $FORGEJO_TOKEN_FILE"
        echo "  sudo chown root:users $FORGEJO_TOKEN_FILE && sudo chmod 640 $FORGEJO_TOKEN_FILE"
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

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  # All three mechanisms, and the reason each exists is spelled out above: the
  # DB dump carries the data, the state tarball carries the secret_key that
  # makes the dump decryptable, and the repositories are already on the HDD.
  nic.services.forgejo = {
    backup            = [ "postgres" "unit" "mnt-data" ];
    postgresDatabases = [ "forgejo" ];
    backupUnits       = [ "forgejo-state-backup.service" ];
    heavyUnits        = [ "forgejo.service" ];
    heavyPriority     = 130;

    # externalPort is also the socket-activate listen (see below), so the literal
    # stays local; only the URL shape is derived.
    public = {
      order   = 170;
      port    = externalPort;
      backend = "http://127.0.0.1:${toString externalPort}";
      tile = {
        name        = "Forgejo";
        icon        = "forgejo.svg";
        category    = "Apps";
        description = "Git hosting";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/forgejo";
          refreshInterval = 3600000;
          mappings = [
            # `Issues` and `PRs` were both structurally 0 — of 167 repositories 68
            # are mirrors and the rest are personal pushes, so no tracker here has
            # ever been used. What this instance is FOR is mirroring, so the second
            # field now asks whether the mirrors are running. It earned itself on
            # the first fetch: all 68 are overdue, newest sync 2026-08-11.
            { field = "repositories";  label = "Repos";   format = "number"; }
            { field = "stale_mirrors"; label = "Overdue"; format = "number"; }
            { field = "size";          label = "Size";    format = "bytes"; }
          ];
        };
      };
    };
  };
}
