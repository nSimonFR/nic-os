{ pkgs, lib, ... }:

let
  beastMac = "c8:7f:54:0a:40:ec";
  beastHost = "beast";

  beast-wake = pkgs.writeShellApplication {
    name = "beast-wake";
    runtimeInputs = [ pkgs.wakeonlan ];
    text = ''
      echo "Waking Beast (${beastMac})..."
      wakeonlan ${beastMac}
    '';
  };

  beast-shutdown = pkgs.writeShellApplication {
    name = "beast-shutdown";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      echo "Shutting down Beast via SSH (${beastHost})..."
      ssh ${beastHost} "sudo shutdown now"
    '';
  };

  beast-toggle = pkgs.writeShellApplication {
    name = "beast-toggle";
    runtimeInputs = [
      pkgs.openssh
      pkgs.wakeonlan
    ];
    text = ''
      if ssh -o BatchMode=yes -o ConnectTimeout=3 ${beastHost} true 2>/dev/null; then
        echo "Beast is reachable; shutting down..."
        ssh ${beastHost} "sudo shutdown now"
      else
        echo "Beast is unreachable; sending Wake-on-LAN..."
        wakeonlan ${beastMac}
      fi
    '';
  };
in
{
  home.packages = [
    beast-wake
    beast-shutdown
    beast-toggle
  ];

  xdg.desktopEntries = lib.mkIf pkgs.stdenv.isLinux {
    beast-wake = {
      name = "Wake Beast";
      genericName = "Wake Beast";
      comment = "Send Wake-on-LAN packet to Beast";
      exec = "${beast-wake}/bin/beast-wake";
      terminal = true;
      categories = [ "System" ];
    };

    beast-shutdown = {
      name = "Shutdown Beast";
      genericName = "Shutdown Beast";
      comment = "Shutdown Beast via SSH";
      exec = "${beast-shutdown}/bin/beast-shutdown";
      terminal = true;
      categories = [ "System" ];
    };

    beast-toggle = {
      name = "Toggle Beast Power";
      genericName = "Toggle Beast Power";
      comment = "Wake Beast if offline, shutdown if reachable";
      exec = "${beast-toggle}/bin/beast-toggle";
      terminal = true;
      categories = [ "System" ];
    };
  };
}
