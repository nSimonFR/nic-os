# Pull-based deploy: the Deck applies nic-os main itself, daily and only on AC.
# Nothing here builds outside cache.nixos.org, so no Cachix push or CI deploy job.
{ pkgs, ... }:
{
  systemd.user.services.nic-os-update = {
    Unit = {
      Description = "Apply nic-os main (home-manager switch)";
      ConditionACPower = true;
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      Environment = [ "PATH=/nix/var/nix/profiles/default/bin:/usr/bin" ];
      ExecStart = "${pkgs.home-manager}/bin/home-manager switch -b hm-backup --refresh --flake github:nSimonFR/nic-os#deck@steamdeck";
    };
  };
  systemd.user.timers.nic-os-update = {
    Unit.Description = "Apply nic-os main daily";
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
