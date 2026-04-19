{ pkgs, ... }:
let
  claudeBin = "/etc/profiles/per-user/nsimon/bin/claude";
in
{
  systemd.services.claude-remote-control = {
    description = "Claude Code Remote Control server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "nsimon";
      Group = "users";
      WorkingDirectory = "/home/nsimon";
      ExecStart = "${claudeBin} remote-control";
      Restart = "on-failure";
      RestartSec = "10s";
      # Claude Code needs access to home dir for config, keys, etc.
      Environment = [
        "HOME=/home/nsimon"
        "PATH=/etc/profiles/per-user/nsimon/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
    };
  };
}
