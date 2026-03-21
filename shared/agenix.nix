{ config, ... }:
{
  age.identityPaths = [ "${config.home.homeDirectory}/.ssh/age" ];
  age.secrets.secrets-zsh.file = ./secrets.zsh.age;
  age.secrets.telegram-bot-token.file = ./telegram-bot-token.age;
}
