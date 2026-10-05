# Run mattpocock's /retro on each T3 Code thread you settle; findings land in
# ~/retros as markdown, never pushed (nic-os is public, a retro quotes its session).
# T3 Code has no on-settle hook, so this polls its DB.
#
# On-demand: sudo systemctl start t3-settle-retro
# Logic: hosts/rpi5/scripts/lib/nicos_scripts/claude/settle_retro.py
# Re-review a thread: drop its entry from ~/retros/.state.json.
{ pkgs, username, ... }:
{
  systemd.services.t3-settle-retro = {
    description = "Run /retro on newly settled T3 Code threads";
    after = [ "t3code.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = username;
      Group = "users";
      ExecStart = "${pkgs.nicos-scripts}/bin/t3-settle-retro";
      # Two reviews per run at RETRO_TIMEOUT each, plus slack.
      TimeoutStartSec = "65min";
      # Never compete with interactive sessions for the Pi's 3.9 GB.
      Nice = 10;
      Environment = [
        "HOME=/home/${username}"
        "PATH=/etc/profiles/per-user/${username}/bin:/run/wrappers/bin:/run/current-system/sw/bin"
        "RETRO_DRY_RUN=0"
      ];
    };
  };

  systemd.timers.t3-settle-retro = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitInactiveSec = "5min";
    };
  };
}
