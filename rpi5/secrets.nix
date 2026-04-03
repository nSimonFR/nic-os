{ config, ... }:
{
  # System-level age identity: stored on the root filesystem so it is
  # available during stage-2 activation (before systemd mounts the RAID-backed
  # /home).  The key is encrypted to nsimon-age (not host SSH keys).
  # Physical location: /root/.ssh/age on NIXOS_SSD.
  age.identityPaths = [ "/root/.ssh/age" ];

  age.secrets = {
    openclaw-env = {
      file = ./secrets/openclaw.env.age;
      owner = "nsimon";
    };
    telegram-bot-token = {
      file = ../shared/telegram-bot-token.age;
      owner = "nsimon";
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
    openclaw-codex-auth = {
      file = ./secrets/openclaw-codex-auth.age;
      owner = "nsimon";
    };
    rclone-storj = {
      file = ./secrets/rclone-storj.age;
    };
    immich-api-key = {
      file = ./secrets/immich-api-key.age;
      owner = "nsimon";
    };
    sure-app-env = {
      file = ./secrets/sure-app-env.age;
      # root-readable (docker reads it as --env-file via systemd root service)
    };
    sure-pg-password = {
      file = ./secrets/sure-pg-password.age;
      owner = "postgres"; # ensurePasswordFile reads as postgres user
    };
    for-sure-api-key = {
      file = ./secrets/for-sure-api-key.age;
      owner = "for-sure";
    };
  };
}
