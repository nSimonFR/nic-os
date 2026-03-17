{ config, ... }:
{
  imports = [ ../shared/agenix.nix ];

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
      group = "firefly-iii";
    };
    linky-prm = {
      file = ../shared/linky-prm.age;
    };
  };
}
