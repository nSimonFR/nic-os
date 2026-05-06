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
    restic-password = {
      file = ./secrets/restic-password.age;
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
    paperless-pg-password = {
      file  = ./secrets/paperless-pg-password.age;
      owner = "postgres"; # paperless-pg-setup runs as postgres and reads this
    };
    paperless-admin-password = {
      file  = ./secrets/paperless-admin-password.age;
      owner = "paperless"; # services.paperless.passwordFile -> LoadCredential
    };
    paperless-env = {
      file  = ./secrets/paperless-env.age;
      owner = "paperless"; # EnvironmentFile for all paperless-* services
      mode  = "0400";
    };
    paperless-api-token = {
      file  = ./secrets/paperless-api-token.age;
      owner = "nsimon"; # homepage-dashboard-env reads this
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
    altserver-pairing-plist = {
      file = ./secrets/altserver-pairing-plist.age;
      # Read by the altserverPairing activation script (root) — no service user.
    };
};
}
