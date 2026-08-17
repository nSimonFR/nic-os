{ config, ... }:
{
  # System-level age identity: stored on the root filesystem so it is
  # available during stage-2 activation (before systemd mounts the RAID-backed
  # /home).  The key is encrypted to nsimon-age (not host SSH keys).
  # Physical location: /root/.ssh/age on NIXOS_SSD.
  age.identityPaths = [ "/root/.ssh/age" ];

  age.secrets = {
    # Shared agent env (skill/tool creds: GOG_*, HA_*, SURE/LINEAR/RYOT keys, …)
    # sourced by the Hermes agent service. Named picoclaw-env historically; kept
    # as agent-env after PicoClaw was retired.
    agent-env = {
      file = ./secrets/agent-env.age;
      owner = "nsimon";
    };
    telegram-bot-token = {
      file  = ../../shared/telegram-bot-token.age;
      owner = "nsimon";
      group = "for-sure";
      mode  = "0440";
    };
    supervisor-token = {
      file = ./secrets/supervisor-token.age;
    };
    linky-token = {
      file = ./secrets/linky-token.age;
    };
    linky-prm = {
      file = ./secrets/linky-prm.age;
    };
    immich-api-key = {
      file = ./secrets/immich-api-key.age;
      owner = "nsimon";
    };
    # The same key, decrypted a second time for the immich user. The CLIP sidecar
    # (immich-clip.nix) runs as `immich` to reach smart_search over the Postgres
    # socket under peer auth, and so cannot read the nsimon-owned 0400 copy above.
    # Same plaintext, different owner — no re-encryption needed.
    immich-clip-api-key = {
      file = ./secrets/immich-api-key.age;
      owner = "immich";
    };
    sure-app-env = {
      file = ./secrets/sure-app-env.age;
      # root-readable; sure-nix reads via EnvironmentFile
    };
    sure-pg-password = {
      file = ./secrets/sure-pg-password.age;
      owner = "postgres"; # ensurePasswordFile reads as postgres user
    };
    airtrail-env = {
      file = ./secrets/airtrail-env.age;
      owner = "airtrail"; # EnvironmentFile for airtrail.service (DB_URL)
      mode = "0400";
    };
    airtrail-pg-password = {
      file = ./secrets/airtrail-pg-password.age;
      owner = "postgres"; # airtrail-pg-setup runs as postgres and reads this
    };
    beaverhabits-env = {
      file = ./secrets/beaverhabits-env.age;
      owner = "beaverhabits"; # EnvironmentFile for beaverhabits.service (signing secrets)
      mode = "0400";
    };
    wealthfolio-env = {
      file = ./secrets/wealthfolio-env.age;
      # EnvironmentFile for wealthfolio.service: WF_SECRET_KEY (encrypts stored
      # broker credentials) + WF_AUTH_PASSWORD_HASH (argon2id login).
      owner = "wealthfolio";
      mode = "0400";
    };
    wealthfolio-mcp-token = {
      file = ./secrets/wealthfolio-mcp-token.age;
      # Read-only agent PAT (wfp_…) for Hermes' Wealthfolio MCP server. Owned by
      # nsimon because hermes.service runs as that user.
      owner = "nsimon";
      mode = "0400";
    };
    etherscan-api-key = {
      file = ./secrets/etherscan-api-key.age;
      # Read-only chain queries — used to trace where crypto moved between the
      # Ledger and Kraken wallets, which is what says whose cost basis is whose.
      # Root-owned because the Sure -> Wealthfolio sync runs as root.
      owner = "root";
      mode = "0400";
    };
    wealthfolio-sync-env = {
      file = ./secrets/wealthfolio-sync-env.age;
      # WF_PASSWORD for the Sure -> Wealthfolio mirror. Root-owned: the sync
      # runs as root so it can `runuser -u postgres` into Sure's database.
      owner = "root";
      mode = "0400";
    };
    ryot-env = {
      file = ./secrets/ryot-env.age;
      owner = "ryot"; # EnvironmentFile for ryot-backend/ryot-frontend (DATABASE_URL + tokens)
      mode = "0400";
    };
    ryot-import-env = {
      file = ./secrets/ryot-import-env.age;
      owner = "ryot"; # EnvironmentFile for ryot-plex-import.service (RYOT_LOGIN_* + PLEX_IMPORT_SERVERS)
      mode = "0400";
    };
    ryot-pg-password = {
      file = ./secrets/ryot-pg-password.age;
      owner = "postgres"; # ryot-pg-setup runs as postgres and reads this
    };
    steam-connector-env = {
      file  = ./secrets/steam-connector-env.age;
      owner = "ryot-connector"; # EnvironmentFile for steam-to-ryot.service
      mode  = "0400";
    };
    spotify-connector-env = {
      file  = ./secrets/spotify-connector-env.age;
      owner = "ryot-connector"; # EnvironmentFile for spotify-to-ryot.service
      mode  = "0400";
    };
    for-sure-api-key = {
      file = ./secrets/for-sure-api-key.age;
      owner = "for-sure";
    };
    vaultwarden-admin-token = {
      file  = ./secrets/vaultwarden-admin-token.age;
      owner = "vaultwarden";
    };
    rclone-storj = {
      file = ./secrets/rclone-storj.age;
    };
    aperture-s3-export = {
      file = ./secrets/aperture-s3-export.age;
      # Storj S3-gateway creds for Aperture's exporters.s3 block.
      # Sourced as KEY=VALUE by aperture-config-sync.service (runs as root).
    };
    restic-password = {
      file = ./secrets/restic-password.age;
    };
    gramps-web-secret = {
      file  = ./secrets/gramps-web-secret.age;
      owner = "gramps-web";
    };
    # AFFiNE session cookie for affine-mcp. Replaces affine-token.age, which held a
    # `ut_…` user access token — a credential type AFFiNE 0.27.3 deleted outright, so
    # it 401ed everywhere and could not be re-minted. Read only by the root-run
    # affine-mcp-env oneshot, hence no world-readable mode.
    affine-mcp-cookie.file = ./secrets/affine-mcp-cookie.age;
    affine-gcal-oauth = {
      file = ./secrets/affine-gcal-oauth.age;
      owner = "affine";
    };
    affine-mcp-http-token = {
      file = ./secrets/affine-mcp-http-token.age;
      mode = "0444"; # DynamicUser (tiny-llm-gate, affine-mcp) needs to read it
    };
    dawarich-geoapify = {
      file  = ./secrets/dawarich-geoapify.age;
      owner = "dawarich";
      mode  = "0440";
    };
    papra-env = {
      file  = ./secrets/papra-env.age;
      owner = "papra"; # EnvironmentFile for papra.service (AUTH_SECRET + OPENAI_API_KEY)
      mode  = "0400";
    };
    papra-webhook-secret = {
      file  = ./secrets/papra-webhook-secret.age;
      owner = "nextcloud"; # HMAC secret for the papra→nextcloud tag-sync receiver
      mode  = "0400";
    };
    nextcloud-pg-password = {
      file  = ./secrets/nextcloud-pg-password.age;
      owner = "postgres"; # nextcloud-pg-setup runs as postgres; nextcloud-setup reads via LoadCredential as PID 1
    };
    # No nextcloud-admin-password agenix entry: install is done; the admin
    # password lives hashed in postgres oc_users and is rotated via
    # `occ user:resetpassword`. See nextcloud.nix for the placeholder.
    protonmail-bridge-password = {
      file  = ./secrets/protonmail-bridge-password.age;
      owner = "hydroxide";
      group = "hydroxide";
      mode  = "0440";
    };
    nextcloud-homepage-password = {
      file  = ./secrets/nextcloud-homepage-password.age;
      owner = "nsimon"; # homepage-dashboard-env reads this
    };
    wakapi-password-salt = {
      file = ./secrets/wakapi-password-salt.age;
      mode = "0444"; # DynamicUser (wakapi) needs to read via EnvironmentFile
    };
    wakapi-smtp-env = {
      file = ./secrets/wakapi-smtp-env.age;
      mode = "0444"; # DynamicUser (wakapi) reads via EnvironmentFile
    };
    wakapi-api-key = {
      file = ./secrets/wakapi-api-key.age;
      mode = "0440";
      # group "wheel" so the daily-import oneshot can read it without
      # owning the file outright.
      group = "wheel";
    };
    reactive-resume-db-password = {
      file = ./secrets/reactive-resume-db-password.age;
      owner = "postgres"; # reactive-resume-pg-setup runs as postgres; reactive-resume-env reads as root
    };
    reactive-resume-auth-secret = {
      file = ./secrets/reactive-resume-auth-secret.age;
      # root-readable; reactive-resume-env (root oneshot) reads it
    };
    reactive-resume-encryption-secret = {
      file = ./secrets/reactive-resume-encryption-secret.age;
      # ENCRYPTION_SECRET (>=32 chars): encrypts per-user AI-provider API keys at
      # rest (packages/api/.../ai/credentials.ts). root-readable; reactive-resume-env
      # (root oneshot) reads it.
    };
    epicgames-account-email = {
      file = ./secrets/epicgames-account-email.age;
      # Not secret, but the repo is public — kept out of git. root-readable;
      # epicgames-freegames-config (root oneshot) reads it into config.json.
    };
    scale-bridge-env = {
      file  = ./secrets/scale-bridge-env.age;
      # RYOT_TOKEN + SHIM_KEY + body-comp profile (USER_HEIGHT/BIRTH_DATE/GENDER).
      # owner scale-bridge (shim reads via EnvironmentFile); root (ble-scale-sync
      # + the config.yaml activation script) reads it regardless of the bits.
      owner = "scale-bridge";
      mode  = "0400";
    };
};
}
