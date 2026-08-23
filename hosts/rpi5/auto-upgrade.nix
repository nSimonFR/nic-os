# auto-upgrade.nix — weekly, unattended: flake update → rebuild → reboot.
#
# Every Sunday 05:00 (after the 03:00–04:00 backup window) a root oneshot:
#   1. `nix flake update` on the live checkout (/home/nsimon/nic-os), run AS
#      nsimon so the rewritten flake.lock stays user-owned and git's
#      dubious-ownership guard is satisfied (the repo is nsimon's).
#   2. Stops the heavy userspace services (shared OOM guard — `nic.heavyServices`,
#      see ./lib/service-registration.nix) so the memory-tight Pi has build headroom and
#      doesn't zram-thrash into a watchdog reset.
#   3. `nixos-rebuild switch` against the (now dirty) working tree. On failure
#      the script aborts BEFORE the reboot line, the new generation is not
#      booted, and the existing systemd-failed monitor (monitoring.nix)
#      Telegram-alerts on the failed unit.
#   4. On success, fires a one-off Telegram message, then schedules a reboot in
#      +1 min so this unit exits cleanly first. The weekly reboot is
#      unconditional (user's choice) and also clears memory-leak buildup.
#
# The reboot ping goes through the one-shot seam (shared/notify.nix `send`),
# NOT the stateful telegramAlert helper — that is for open/resolve incidents —
# and NOT the :8088 aggregator, which would debounce it for up to 15 min and so
# lose it across the reboot scheduled one minute later. Telegram being down
# never fails the unit.
#
# Notes / risks:
#   - `nix flake update` bumps ALL inputs (nixpkgs, nixos-raspberrypi, sure-nix,
#     hermes-agent, …). A bad bump can produce a generation that fails to boot;
#     this is a headless Pi, so recovery would need a physical power-cycle. This
#     is the inherent cost of unattended update+reboot and was accepted.
#   - flake.lock is left uncommitted in the working tree (matches how the
#     deployed lock == live state). `git status` will show it modified; review
#     and land it via a normal PR whenever you like.
{ config, lib, pkgs, telegramChatId, ... }:
let
  flakeDir = "/home/nsimon/nic-os";
  owner = "nsimon";
  heavyServices = config.nic.heavyServices;
  tokenFile = config.age.secrets.telegram-bot-token.path;
  telegramSend = (import ../../shared/notify.nix { inherit pkgs; }).send {
    inherit tokenFile;
    chatId = telegramChatId;
    name = "auto-upgrade-telegram-send";
  };
in
{
  systemd.services.nixos-auto-upgrade = {
    description = "Weekly flake update + nixos-rebuild switch + reboot";

    # Fetching inputs needs the network; building needs the daemon.
    after = [ "network-online.target" "nix-daemon.service" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      nix
      nixos-rebuild
      git
      systemd      # systemctl, shutdown
      util-linux   # runuser
      coreutils    # df, readlink, basename
      gnugrep
      curl         # reboot notification
      bash
    ];

    serviceConfig = {
      Type = "oneshot";
      # A full nixpkgs bump can build for hours on the Pi with --max-jobs 1.
      TimeoutStartSec = "6h";
      # systemd gives a service no HOME, and `git config --global` is fatal
      # without one ("fatal: $HOME not set", exit 128) — which killed the whole
      # unit at the safe.directory step below, before any rebuild. Point it at
      # root's real home so the global config is the same file an interactive
      # `sudo git` writes.
      Environment = [ "HOME=/root" ];
    };

    script = ''
      set -euo pipefail
      FLAKE=${lib.escapeShellArg flakeDir}

      echo "auto-upgrade: disk before update/build:" >&2
      df -h /nix /mnt/data >&2 2>/dev/null || true

      # 1. Update flake inputs as the repo owner (keeps flake.lock user-owned,
      #    passes git's dubious-ownership check since the repo is nsimon's).
      echo "auto-upgrade: nix flake update…" >&2
      runuser -u ${owner} -- bash -c "cd \"$FLAKE\" && nix flake update"

      # Let root's git/nix trust the user-owned repo for the rebuild step.
      git config --global --get-all safe.directory | grep -qxF "$FLAKE" \
        || git config --global --add safe.directory "$FLAKE"

      # 2. OOM guard: stop the heavy services before building.
      echo "auto-upgrade: stopping heavy services to free memory…" >&2
      systemctl stop \
        ${lib.concatStringsSep " \\\n        " heavyServices} || true

      # 3. Build + activate the new generation. Aborts here on any failure —
      #    reboot below is never reached, so the box stays on the old gen.
      echo "auto-upgrade: nixos-rebuild switch…" >&2
      nixos-rebuild switch --flake "$FLAKE#rpi5"

      echo "auto-upgrade: disk after build:" >&2
      df -h /nix /mnt/data >&2 2>/dev/null || true

      # 4. Notify (fire-and-forget), then reboot in +1 min so this unit records
      #    success first.
      echo "auto-upgrade: rebuild OK — notifying + scheduling reboot (+1 min)" >&2
      NEWGEN=$(basename "$(readlink -f /run/current-system 2>/dev/null || echo unknown)")
      MSG="🔄 <b>rpi5 auto-upgrade</b>
Weekly flake update + rebuild done.
New system: <code>$NEWGEN</code>
Rebooting in ~1 min."
      ${telegramSend} "$MSG" >/dev/null || true

      shutdown -r +1 "nixos-auto-upgrade: weekly reboot after flake update + rebuild"
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
