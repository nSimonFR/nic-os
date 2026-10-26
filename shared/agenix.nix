{ config, lib, ... }:
let
  files = {
    secrets-zsh = ./secrets.zsh.age;
    telegram-bot-token = ./telegram-bot-token.age;
    mcp-secrets = ./mcp-secrets.age;
    wakatime-cfg = ./wakatime.cfg.age;
  };
  fromSystem = config.nic.userSecretsFromSystem;
in
{
  options.nic = {
    # The host's system agenix decrypts these instead, so the user holds no age
    # identity. A secret the host doesn't declare is simply absent.
    userSecretsFromSystem = lib.mkEnableOption "user secrets from /run/agenix";
    userSecrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "Decrypted path of each user secret.";
    };
  };

  config = lib.mkMerge [
    {
      nic.userSecrets = lib.mapAttrs
        (n: _: if fromSystem then "/run/agenix/${n}" else config.age.secrets.${n}.path)
        files;
    }
    (lib.mkIf (!fromSystem) {
      age.identityPaths = [ "${config.home.homeDirectory}/.ssh/age" ];
      age.secrets = lib.mapAttrs (_: file: { inherit file; }) files;
    })
  ];
}
