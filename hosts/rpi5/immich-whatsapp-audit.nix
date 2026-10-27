{ config, pkgs, telegramChatId, ... }:
# Weekly guard on the Immich workflow that archives WhatsApp (UUID-named) images:
# disables it on drift, flags likely false positives and volume spikes. See
# nicos_scripts/immich/whatsapp_audit.py. Silent when all is well; a failed run
# surfaces through systemd-failed-alert.
#
# Runs as `immich`, like the CLIP sidecar: peer auth reads the DB over the socket
# and the immich-owned key copy disables the workflow. The Telegram token is
# root-only to this user, hence LoadCredential.
let
  telegramSend = (import ../../shared/notify.nix { inherit pkgs; }).send {
    tokenFile = "\${CREDENTIALS_DIRECTORY}/telegram";
    chatId = telegramChatId;
    name = "immich-whatsapp-audit-telegram-send";
  };
in
{
  systemd.services.immich-whatsapp-audit = {
    description = "Audit the Immich WhatsApp auto-archive workflow";
    after = [ "postgresql.service" "immich-server.service" ];
    path = [ config.services.postgresql.package ];
    environment = {
      IMMICH_API_KEY_FILE = config.age.secrets.immich-clip-api-key.path;
      TELEGRAM_SEND = "${telegramSend}";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "immich";
      Group = "immich";
      LoadCredential = "telegram:${config.age.secrets.telegram-bot-token.path}";
      ExecStart = "${pkgs.nicos-scripts}/bin/immich-whatsapp-audit";
    };
  };

  systemd.timers.immich-whatsapp-audit = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon 10:00";
      Persistent = true;
    };
  };
}
