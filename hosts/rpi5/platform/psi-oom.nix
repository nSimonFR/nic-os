# Freeze nix-daemon, stop expendable units, then kill the largest process, on a
# sustained memory stall
# (nicos_scripts/monitoring/psi_oom.py).
# 5 watchdog resets 2026-11-05/06 (RSTS 0x20, 5.07 V, no kernel line before
# any of them): earlyoom read 27-48% MemAvailable in the last hour and MGLRU
# min_ttl_ms never fired. PSI `full` is the stall itself.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Units psi-oom may stop on a memory stall before it kills anything, so the
  # RAM goes to whatever is working (T3 sessions, mostly). Each service's own
  # module opts in: `nic.psiOom.shed = [ "foo.service" ];`.
  options.nic.psiOom.shed = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Expendable units, stopped largest first on a stall and started again once it is over.";
  };
  options.nic.psiOom.shedRestoreSec = lib.mkOption {
    type = lib.types.ints.positive;
    default = 900;
    description = "Seconds without a stall before shed units are started again.";
  };

  config = {
    # PSI is built in but off by default in the rpi kernel (PSI_DEFAULT_DISABLED).
    # It needs no memory cgroup, so cgroup_disable=memory stays.
    boot.kernelParams = [ "psi=1" ];

    systemd.services.psi-oom = {
      description = "Freeze nix-daemon, stop expendable units or kill the largest process on a memory stall";
      wantedBy = [ "multi-user.target" ];
      # Absent until the first boot with psi=1.
      unitConfig.ConditionPathExists = "/proc/pressure/memory";
      environment.PSI_OOM_DRY_RUN = "0";
      environment.PSI_OOM_LAST_RESORT = "hermes.service";
      environment.PSI_OOM_SHED = lib.concatStringsSep " " (lib.unique config.nic.psiOom.shed);
      environment.PSI_OOM_SHED_RESTORE_SEC = toString config.nic.psiOom.shedRestoreSec;
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
  };
}
