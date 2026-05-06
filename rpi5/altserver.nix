{ config, pkgs, lib, ... }:
# AltServer-Linux on rpi5 for iOS app refresh. Architecture:
#
#   netmuxd (prebuilt) — discovers the iPhone via mDNS (_apple-mobdev2._tcp)
#     on the LAN and bridges its lockdownd protocol over a local unix socket
#     where AltServer expects usbmuxd to be.
#   AltServer (prebuilt, daemon mode) — listens for AltStore refresh requests
#     from the iPhone (manual server-IP entry on iPhone side; tailnet works).
#     Anisette token endpoint via $ALTSERVER_ANISETTE_SERVER.
#
# Apple ID is NOT configured here: AltStore on the iPhone stores it locally
# and sends it with each refresh request, so the server runs without creds.
#
# The pairing trust record is staged from agenix into /var/lib/lockdown/<UDID>.plist
# at activation time. The plist content is the user's macOS lockdownd record
# (libimobiledevice's on-disk format matches macOS's by design).
let
  altserverPkg = pkgs.callPackage ./altserver/altserver-linux.nix { };
  netmuxdPkg   = pkgs.callPackage ./altserver/netmuxd.nix { };

  # 40-char hex from /var/db/lockdown/<UDID>.plist on the Mac. Set this before
  # the first rebuild that actually intends to talk to the iPhone — the activation
  # script no-ops cleanly while it's still REPLACE_ME (the agenix file may also
  # be absent until you've encrypted it).
  iPhoneUdid = "REPLACE_ME";
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/lockdown 0700 root root -"
  ];

  # Stage the pairing record into libimobiledevice's expected location. Skips
  # cleanly if either the agenix secret or the UDID placeholder is missing,
  # so the module can land before the secret is encrypted.
  system.activationScripts.altserverPairing = lib.stringAfter [ "agenix" ] ''
    if [ "${iPhoneUdid}" != "REPLACE_ME" ] && [ -r /run/agenix/altserver-pairing-plist ]; then
      install -d -m 700 /var/lib/lockdown
      install -m 600 -o root -g root \
        /run/agenix/altserver-pairing-plist \
        /var/lib/lockdown/${iPhoneUdid}.plist
    fi
  '';

  # mDNS resolution for the iPhone's _apple-mobdev2._tcp.local advertisement.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish.enable = false;
  };

  systemd.services.netmuxd = {
    description = "netmuxd — network multiplexer for iOS";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "avahi-daemon.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${netmuxdPkg}/bin/netmuxd";
      Restart = "on-failure";
      RestartSec = "10s";
      MemoryMax = "128M";
    };
  };

  systemd.services.altserver = {
    description = "AltServer-Linux — iOS app refresh daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "netmuxd.service" "network-online.target" ];
    requires = [ "netmuxd.service" ];
    environment = {
      ALTSERVER_ANISETTE_SERVER = "https://ani.sidestore.io";
    };
    serviceConfig = {
      ExecStart = "${altserverPkg}/bin/alt-server";
      Restart = "on-failure";
      RestartSec = "30s";
      MemoryMax = "256M";
    };
  };
}
