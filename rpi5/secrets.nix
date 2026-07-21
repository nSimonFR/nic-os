{ config, ... }:
{
  # System-level age identity: stored on the root filesystem so it is
  # available during stage-2 activation (before systemd mounts the RAID-backed
  # /home).  The key is encrypted to nsimon-age (not host SSH keys).
  # Physical location: /root/.ssh/age on NIXOS_SSD.
  age.identityPaths = [ "/root/.ssh/age" ];

  age.secrets = {
    picoclaw-env = {
      file = ./secrets/picoclaw-env.age;
      owner = "nsimon";
    };
    telegram-bot-token = {
      file  = ../shared/telegram-bot-token.age;
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
    affine-token = {
      file = ./secrets/affine-token.age;
      mode = "0444"; # DynamicUser (tiny-llm-gate MCP bridge, affine-mcp) needs to read it
    };
    affine-gcal-oauth = {
      file = ./secrets/affine-gcal-oauth.age;
      owner = "affine";
    };
    affine-mcp-http-token = {
      file = ./secrets/affine-mcp-http-token.age;
      mode = "0444"; # DynamicUser (tiny-llm-gate, affine-mcp) needs to read it
    };
    tavily-api-key = {
      file = ./secrets/tavily-api-key.age;
      mode = "0444"; # DynamicUser (open-webui) needs to read it
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
