{ config, ... }:
{
  age.secrets = {
    openclaw-env = {
      file = ../secrets/openclaw.env.age;
      owner = "nsimon";
    };
    telegram-bot-token = {
      file = ../secrets/telegram-bot-token.age;
      owner = "nsimon";
    };
    supervisor-token = {
      file = ../secrets/supervisor-token.age;
    };
    linky-token = {
      file = ../secrets/linky-token.age;
    };
    firefly-app-key = {
      file = ../secrets/firefly-app-key.age;
      owner = "firefly-iii";
      group = "firefly-iii";
    };
  };
}
