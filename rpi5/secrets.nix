{ config, ... }:
{
  # System-level age identity: use the user's personal age key file.
  # Secrets are encrypted to nsimon-age (not host SSH keys), so we must
  # point the NixOS agenix module at the user's key on the rpi5 filesystem.
  age.identityPaths = [ "/home/nsimon/.ssh/age" ];

  age.secrets = {
    openclaw-env = {
      file = ../shared/openclaw.env.age;
      owner = "nsimon";
    };
    telegram-bot-token = {
      file = ../shared/telegram-bot-token.age;
      owner = "nsimon";
    };
    supervisor-token = {
      file = ../shared/supervisor-token.age;
    };
    linky-token = {
      file = ../shared/linky-token.age;
    };
    firefly-app-key = {
      file = ../shared/firefly-app-key.age;
      owner = "firefly-iii";
      group = "nginx"; # firefly-iii user's primary group; no separate firefly-iii group exists
    };
    linky-prm = {
      file = ../shared/linky-prm.age;
    };
  };
}
