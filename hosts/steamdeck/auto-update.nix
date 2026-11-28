# Pull-based deploy: the Deck applies nic-os main itself.
# Nothing here builds outside cache.nixos.org, so no Cachix push or CI deploy job.
# The Deck sleeps most of the time and only stays awake on AC (nic-ac-keepawake), so
# check hourly, act only on AC, and at most once per ~day: a run due during sleep
# fires on wake, and a skipped or failed one is retried the next hour.
{ config, pkgs, ... }:
let
  stamp = "${config.xdg.stateHome}/nic-os-update.stamp";
  due = pkgs.writeShellScript "nic-os-update-due" ''
    [ -z "$(find ${stamp} -mmin -1200 2>/dev/null)" ]
  '';
in
{
  systemd.user.services.nic-os-update = {
    Unit = {
      Description = "Apply nic-os main (home-manager switch)";
      ConditionACPower = true;
      # The switch it runs must not restart it mid-run.
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "oneshot";
      Environment = [ "PATH=/nix/var/nix/profiles/default/bin:/usr/bin" ];
      ExecCondition = "${due}";
      ExecStart = "${pkgs.home-manager}/bin/home-manager switch -b hm-backup --refresh --flake github:nSimonFR/nic-os#deck@steamdeck";
      ExecStartPost = "${pkgs.coreutils}/bin/touch ${stamp}";
    };
  };
  systemd.user.timers.nic-os-update = {
    Unit.Description = "Apply nic-os main when on AC, at most daily";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
