# beast power discipline. beast may only be ON or OFF — suspend is disabled in
# hosts/beast/configuration.nix (s2idle freezes PID 1, the SP5100 watchdog
# force-resets after 120s) and nothing on the box turns it off, so every wake is
# permanent until a human notices. Two halves, because discipline alone does not
# hold: `beast-wake` arms a 1h self-expiring poweroff on beast, and
# `beast-idle-alert` pages every 4h for whatever bypassed it. The rpi5 owns both
# — WOL is layer-2 only and this is the only box on beast's LAN, and a watcher
# has to outlive what it watches.
{ config, pkgs, lib, telegramChatId, ... }:
let
  # Send-once / edit-in-place / auto-resolve: "beast is idling" is a condition
  # that clears, not a one-shot event.
  telegramAlert = (import ../../shared/notify.nix { inherit pkgs; }).alert {
    tokenFile = config.age.secrets.telegram-bot-token.path;
    chatId = telegramChatId;
    name = "telegram-alert-beast";
  };

  # The guard is pushed to beast's /run at wake time rather than baked into its
  # closure, so it always matches the beast-wake that armed it.
  beastWake = pkgs.writeShellApplication {
    name = "beast-wake";
    runtimeInputs = [ pkgs.wakeonlan pkgs.openssh pkgs.coreutils ];
    text = ''
      BEAST_AUTOPOWEROFF_SCRIPT=${./scripts/beast-auto-poweroff.sh}
    ''
    + builtins.readFile ./scripts/beast-wake.sh;
  };

  beastIdleAlert = pkgs.writeShellApplication {
    name = "beast-idle-alert";
    runtimeInputs = [
      pkgs.tailscale
      pkgs.jq
      pkgs.gnugrep
      pkgs.gawk
      pkgs.coreutils
      pkgs.util-linux # runuser — the ssh hop goes as nsimon, not root
    ];
    text = ''
      TELEGRAM_ALERT=${telegramAlert}
    ''
    + builtins.readFile ./scripts/beast-idle-alert.sh;
  };
in
{
  # On PATH for humans and agents alike, in place of a bare `wakeonlan <mac>`.
  environment.systemPackages = [ beastWake ];

  systemd.services.beast-idle-alert = {
    description = "Alert when beast is powered on with nobody using it";
    # Root reads the age-encrypted bot token; the script drops to nsimon to ssh.
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe beastIdleAlert;
    };
  };

  systemd.timers.beast-idle-alert = {
    description = "Four-hourly check that beast is not idling powered-on";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "4h";
      Persistent = true; # an idling beast outlasts a Pi reboot
    };
  };
}
