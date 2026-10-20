# Arkose+ (SocialBoulder) climbing sessions -> /var/lib/arkose-sync/sessions.json,
# then pushed to FreeReps' climbing ingest (the fork in pkgs/services/freereps.nix).
#
# No password is stored. The tailnet-mitm addon captures the app's resume token
# when the phone opens Arkose+ on the tailnet (expiry 2126, so valid until the
# app logs out); that write starts arkose-sync. An hourly timer re-runs it for
# tops logged after the first open and as a daily fallback; idle runs exit
# before any network I/O (see nicos_scripts/connectors/arkose.py).
#
# A logged-out token makes the unit fail -> systemd-failed-alert on Telegram.
# Fix: open the app on the tailnet.
#
# Both hosts sit on Meteor Galaxy's shared ingress (57.130.73.159), so the
# phone's other Galaxy-hosted apps also route via rpi5, passed through
# undecrypted; while rpi5 is down they (and Arkose+) can't connect.
# IPv4 only: there is no AAAA today; one would bypass the capture.
{ pkgs, ... }:
let
  dir = "/var/lib/arkose-sync";
  # tailnet-mitm's user; its addon writes token.json here.
  mitmGroup = "sumeria-mitm";
in
{
  services.tailnet-mitm.targets.arkose = {
    hosts = [ "plus.arkose.com" "www.sboulder.com" ];
    allowHosts = "^(plus\\.arkose\\.com|(www\\.)?sboulder\\.com):";
    addon = "${pkgs.nicos-scripts}/${pkgs.python3.sitePackages}/nicos_scripts/mitm/arkose.py";
  };

  users.users.arkose-sync = { isSystemUser = true; group = "arkose-sync"; };
  users.groups.arkose-sync = { };

  systemd.tmpfiles.rules = [ "d ${dir} 0770 arkose-sync ${mitmGroup} - -" ];

  systemd.services.arkose-sync = {
    description = "Sync Arkose+ climbing sessions";
    after = [ "network-online.target" "freereps-proxy.socket" ];
    wants = [ "network-online.target" ];
    environment = {
      ARKOSE_DIR = dir;
      # The socket-activation proxy: the only address that wakes FreeReps.
      ARKOSE_FREEREPS_URL = "http://127.0.0.1:8370";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "arkose-sync";
      Group = "arkose-sync";
      ExecStart = "${pkgs.nicos-scripts}/bin/arkose-sync";
      TimeoutStartSec = "5min";
      ProtectSystem = "strict";
      ReadWritePaths = [ dir ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.paths.arkose-sync = {
    description = "Run arkose-sync when the app's token is captured";
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = "${dir}/token.json";
  };

  systemd.timers.arkose-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "5m";
    };
  };
}
