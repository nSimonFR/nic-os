{ pkgs, lib, ... }:
let
  dataDir = "/var/lib/manticoresearch";
  httpPort = 9308;

  config = pkgs.writeText "manticore.conf" ''
    searchd {
      listen = 127.0.0.1:${toString httpPort}:http
      log = /var/log/manticoresearch/searchd.log
      query_log = /var/log/manticoresearch/query.log
      pid_file = /run/manticoresearch/searchd.pid
      data_dir = ${dataDir}
    }
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 manticoresearch manticoresearch -"
    "d /var/log/manticoresearch 0750 manticoresearch manticoresearch -"
    "d /run/manticoresearch 0755 manticoresearch manticoresearch -"
  ];

  users.users.manticoresearch = {
    isSystemUser = true;
    group = "manticoresearch";
    home = dataDir;
  };
  users.groups.manticoresearch = { };

  systemd.services.manticoresearch = {
    description = "Manticore Search";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "forking";
      PIDFile = "/run/manticoresearch/searchd.pid";
      ExecStart = "${pkgs.manticoresearch}/bin/searchd --config ${config}";
      ExecStop = "${pkgs.manticoresearch}/bin/searchd --config ${config} --stopwait";
      User = "manticoresearch";
      Group = "manticoresearch";
      Restart = "on-failure";
      RestartSec = "5s";
      PrivateUsers = lib.mkForce false;
    };
  };
}
