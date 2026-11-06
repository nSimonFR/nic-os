# Kernel OOM kill on a sustained memory stall (nicos_scripts/monitoring/psi_oom.py).
# 5 watchdog resets 2026-11-05/06 (RSTS 0x20, 5.07 V, no kernel line before
# any of them): earlyoom read 27-48% MemAvailable in the last hour and MGLRU
# min_ttl_ms never fired. PSI `full` is the stall itself.
{ pkgs, ... }:
{
  # PSI is built in but off by default in the rpi kernel (PSI_DEFAULT_DISABLED).
  # It needs no memory cgroup, so cgroup_disable=memory stays.
  boot.kernelParams = [ "psi=1" ];

  systemd.services.psi-oom = {
    description = "Kernel OOM kill on a sustained memory stall";
    wantedBy = [ "multi-user.target" ];
    # Absent until the first boot with psi=1.
    unitConfig.ConditionPathExists = "/proc/pressure/memory";
    environment.PSI_OOM_DRY_RUN = "0";
    serviceConfig = {
      ExecStart = "${pkgs.nicos-scripts}/bin/psi-oom";
      Restart = "always";
      RestartSec = 5;
      OOMScoreAdjust = -1000;
      # Must get the CPU while everything else is stalled.
      CPUSchedulingPolicy = "fifo";
      CPUSchedulingPriority = 50;
      LimitMEMLOCK = "infinity";
    };
  };
}
