{ config, pkgs, ... }:
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

  # Siyuan notes (data/) live on HDD for cloud backup replication.
  # Config, history, and temp stay on SSD for speed.
  systemd.mounts = [{
    where = "${dataDir}/data";
    what = "/mnt/data/services/siyuan-data";
    type = "none";
    options = "bind";
    after = [ "mnt-data.mount" ];
    requires = [ "mnt-data.mount" ];
    wantedBy = [ "local-fs.target" ];
  }];

  systemd.tmpfiles.rules = [
    "d /mnt/data/services/siyuan-data 0750 siyuan siyuan -"
  ];

  systemd.services.siyuan = {
    description = "SiYuan Notes";
    after = [ "network.target" "var-lib-siyuan-data.mount" ];
    requires = [ "var-lib-siyuan-data.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "siyuan";
      Group = "siyuan";
      StateDirectory = "siyuan";
      WorkingDirectory = dataDir;
      ExecStart = pkgs.writeShellScript "siyuan-start" ''
        export RUN_IN_CONTAINER=true
        AUTH_CODE=$(cat ${config.age.secrets.siyuan-auth-code.path})
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
