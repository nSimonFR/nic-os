{ pkgs, ... }:
let
  port = 6806;
  dataDir = "/var/lib/siyuan";
in
{
  users.users.siyuan = {
    isSystemUser = true;
    group = "siyuan";
    home = dataDir;
  };
  users.groups.siyuan = { };

  systemd.services.siyuan = {
    description = "SiYuan Notes";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    environment.RUN_IN_CONTAINER = "true";
    serviceConfig = {
      Type = "simple";
      User = "siyuan";
      Group = "siyuan";
      StateDirectory = "siyuan";
      WorkingDirectory = dataDir;
      ExecStart = pkgs.writeShellScript "siyuan-start" ''
        export RUN_IN_CONTAINER=true
        AUTH_CODE=$(cat /run/agenix/siyuan-auth-code)
        exec ${pkgs.siyuan.kernel}/bin/kernel \
          -port ${toString port} \
          -workspace ${dataDir} \
          -wd ${pkgs.siyuan}/share/siyuan/resources \
          -accessAuthCode "$AUTH_CODE"
      '';
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
