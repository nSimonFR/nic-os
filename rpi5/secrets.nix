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
    firefly-app-key = {
      file = ./secrets/firefly-app-key.age;
      owner = "firefly-iii";
      group = "nginx"; # firefly-iii user's primary group; no separate firefly-iii group exists
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
  };
}
