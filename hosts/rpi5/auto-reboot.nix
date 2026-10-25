# auto-reboot.nix — weekly reboot, only when a deploy left a new kernel pending.
#
# Deploys come from CI (deploy-rpi5.yml → cachix-agent.nix), which switches but
# never reboots, so a new kernel, initrd or module set waits here for Sunday
# 05:00 (after the 03:00–04:30 backup window). Nothing pending → no reboot.
#
# The reboot ping goes through the one-shot seam (shared/notify.nix `send`), not
# the :8088 aggregator, which would debounce it past the reboot.
{ config, pkgs, telegramChatId, ... }:
let
  telegramSend = (import ../../shared/notify.nix { inherit pkgs; }).send {
    tokenFile = config.age.secrets.telegram-bot-token.path;
    chatId = telegramChatId;
    name = "auto-reboot-telegram-send";
  };

  autoReboot = pkgs.writeShellApplication {
    name = "auto-reboot";
    runtimeInputs = with pkgs; [ coreutils systemd ];
    text = ''
      pending=()
      for f in kernel initrd kernel-modules; do
        if [ "$(readlink -f "/run/booted-system/$f")" != "$(readlink -f "/run/current-system/$f")" ]; then
          pending+=("$f")
        fi
      done

      if [ ''${#pending[@]} -eq 0 ]; then
        echo "auto-reboot: booted system is current, nothing to do"
        exit 0
      fi

      echo "auto-reboot: changed since boot: ''${pending[*]}"
      ${telegramSend} "🔄 <b>rpi5 auto-reboot</b>
Changed since boot: <code>''${pending[*]}</code>
Rebooting in ~1 min." >/dev/null || true

      # +1 min so this unit records success before the reboot.
      shutdown -r +1 "auto-reboot: ''${pending[*]} changed since boot"
    '';
  };
in
{
  systemd.services.auto-reboot = {
    description = "Reboot if a deploy left a new kernel pending";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${autoReboot}/bin/auto-reboot";
    };
  };

  systemd.timers.auto-reboot = {
    description = "Weekly pending-kernel reboot (Sun 05:00)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 05:00:00";
      Persistent = true;
    };
  };
}
