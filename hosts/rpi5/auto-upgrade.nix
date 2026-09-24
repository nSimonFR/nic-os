# auto-upgrade.nix — weekly, unattended: rebuild from main → reboot.
#
# Every Sunday 05:00 (after the 03:00–04:00 backup window) a root oneshot:
#   1. `nixos-rebuild switch` against `github:nSimonFR/nic-os/main`, wrapped in
#      `nic.heavyShed` (./lib/service-registration.nix), which stops the heavy
#      services so eval doesn't zram-thrash the Pi into a watchdog reset, and
#      restores them if the build fails. On failure it aborts before the reboot
#      and the systemd-failed monitor (monitoring.nix) alerts on Telegram.
#   2. On success, a one-off Telegram message, then a reboot in +1 min so this
#      unit exits cleanly first. The weekly reboot is unconditional.
#
# It deploys main, never a lock of its own: inputs move through Renovate's
# lock-file-maintenance PR, whose `substitutes` job builds anything
# cache.nixos.org lacks into nsimon-nicos. So this only downloads. It also
# ignores the live checkout, which is often on a feature branch.
#
# The reboot ping goes through the one-shot seam (shared/notify.nix `send`), not
# the :8088 aggregator, which would debounce it past the reboot.
{ config, lib, pkgs, telegramChatId, ... }:
let
  tokenFile = config.age.secrets.telegram-bot-token.path;
  telegramSend = (import ../../shared/notify.nix { inherit pkgs; }).send {
    inherit tokenFile;
    chatId = telegramChatId;
    name = "auto-upgrade-telegram-send";
  };
in
{
  systemd.services.nixos-auto-upgrade = {
    description = "Weekly nixos-rebuild switch from main + reboot";

    # Fetching main needs the network; building needs the daemon.
    after = [ "network-online.target" "nix-daemon.service" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      nix
      nixos-rebuild
      systemd      # systemctl, shutdown
      coreutils    # df, readlink, basename
      curl         # reboot notification
      bash
    ];

    serviceConfig = {
      Type = "oneshot";
      # Downloads only, but a derivation that skipped CI still builds here.
      TimeoutStartSec = "3h";
      # nix's fetcher cache lives under $HOME; systemd gives a service none.
      Environment = [ "HOME=/root" ];
    };

    script = ''
      set -euo pipefail

      echo "auto-upgrade: disk before build:" >&2
      df -h /nix /mnt/data >&2 2>/dev/null || true

      # --refresh: without it nix reuses a cached main tarball for up to an hour.
      echo "auto-upgrade: nixos-rebuild switch from main…" >&2
      ${config.nic.heavyShed}/bin/heavy-shed nixos-rebuild switch --refresh \
        --flake "github:nSimonFR/nic-os/main#rpi5"

      echo "auto-upgrade: disk after build:" >&2
      df -h /nix /mnt/data >&2 2>/dev/null || true

      # Notify (fire-and-forget), then reboot in +1 min so this unit records
      # success first.
      echo "auto-upgrade: rebuild OK — notifying + scheduling reboot (+1 min)" >&2
      NEWGEN=$(basename "$(readlink -f /run/current-system 2>/dev/null || echo unknown)")
      MSG="🔄 <b>rpi5 auto-upgrade</b>
Weekly rebuild from main done.
New system: <code>$NEWGEN</code>
Rebooting in ~1 min."
      ${telegramSend} "$MSG" >/dev/null || true

      shutdown -r +1 "nixos-auto-upgrade: weekly reboot after rebuild from main"
    '';
  };

  systemd.timers.nixos-auto-upgrade = {
    description = "Weekly nixos auto-upgrade timer (Sun 05:00)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 05:00:00";
      Persistent = true; # catch up if the Pi was off at the scheduled time
    };
  };
}
